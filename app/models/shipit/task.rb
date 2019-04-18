module Shipit
  class Task < ActiveRecord::Base
    include DeferredTouch

    ConcurrentTaskRunning = Class.new(StandardError)

    PRESENCE_CHECK_TIMEOUT = 15
    ACTIVE_STATUSES = %w(pending running aborting).freeze
    COMPLETED_STATUSES = %w(success flapping faulty validating).freeze
    UNSUCCESSFUL_STATUSES = %w(error failed aborted flapping timedout faulty).freeze

    attr_accessor :pid

    belongs_to :deploy, foreign_key: :parent_id, required: false, inverse_of: false # required for fixtures

    belongs_to :user, optional: true
    belongs_to :aborted_by, class_name: 'User', optional: true
    belongs_to :stack, counter_cache: true
    belongs_to :until_commit, class_name: 'Commit'
    belongs_to :since_commit, class_name: 'Commit'

    deferred_touch stack: :updated_at

    has_many :chunks, -> { order(:id) }, class_name: 'OutputChunk', dependent: :delete_all, inverse_of: :task

    serialize :definition, TaskDefinition
    serialize :env, Hash

    scope :success, -> { where(status: 'success') }
    scope :completed, -> { where(status: COMPLETED_STATUSES) }
    scope :active, -> { where(status: ACTIVE_STATUSES) }
    scope :exclusive, -> { where(allow_concurrency: false) }
    scope :unsuccessful, -> { where(status: UNSUCCESSFUL_STATUSES) }

    scope :due_for_rollup, -> { completed.where(rolled_up: false).where('created_at <= ?', 1.hour.ago) }

    after_save :record_status_change
    after_create :prevent_concurrency, unless: :allow_concurrency?
    after_commit :emit_hooks

    class << self
      def durations
        pluck(:started_at, :ended_at).select { |s, e| s && e }.map { |s, e| e - s }
      end

      def last_completed
        completed.last
      end

      def current
        active.exclusive.last
      end
    end

    state_machine :status, initial: :pending do
      before_transition any => :running do |task|
        task.started_at ||= Time.now.utc
      end

      before_transition running: any do |task|
        task.ended_at ||= Time.now.utc
      end

      after_transition any => %i(success failed error timedout) do |task|
        task.async_refresh_deployed_revision
      end

      after_transition any => :flapping do |task|
        task.update!(confirmations: 0)
      end

      after_transition any => :success do |task|
        task.async_update_estimated_deploy_duration
      end

      event :run do
        transition pending: :running
      end

      event :failure do
        transition %i(running flapping) => :failed
      end

      event :complete do
        transition %i(running flapping validating faulty) => :success
      end

      event :enter_validation do
        transition %i(running flapping) => :validating
      end

      event :mark_faulty do
        transition %i(validating success) => :faulty
      end

      event :error do
        transition all => :error
      end

      event :giveup do # :timeout would cause a name clash
        transition all => :timedout
      end

      event :aborting do
        transition all - %i(aborted) => :aborting
      end

      event :aborted do
        transition aborting: :aborted
      end

      event :flap do
        transition %i(failed error timedout success) => :flapping
      end

      state :pending
      state :running
      state :validating
      state :faulty
      state :failed
      state :success
      state :error
      state :timedout
      state :aborting
      state :aborted
      state :flapping
    end

    def active?
      status.in?(ACTIVE_STATUSES)
    end

    def report_complete!
      complete!
    end

    def report_failure!(error)
      reload
      if aborting?
        aborted!
      elsif error.respond_to?(:exit_code) && Shipit.timeout_exit_codes.include?(error.exit_code)
        giveup!
      else
        failure!
      end
    end

    def report_timeout!(_error)
      giveup!
    end

    def report_error!(error)
      write("#{error.class}: #{error.message}\n\t#{error.backtrace.join("\n\t")}\n")
      error!
    end

    delegate :acquire_git_cache_lock, :async_refresh_deployed_revision, :async_update_estimated_deploy_duration,
             to: :stack

    delegate :checklist, to: :definition

    def duration?
      started_at? && ended_at?
    end

    def duration
      Duration.new(ended_at - started_at) if duration?
    end

    def spec
      @spec ||= DeploySpec::FileSystem.new(working_directory, stack.environment)
    end

    def enqueue(skip_queue: false)
      raise "only persisted jobs can be enqueued" unless persisted?
      skip_queue ? PerformTaskJob.perform_now(self) : PerformTaskJob.perform_later(self)
    end

    def write(text)
      chunks.create!(text: text)
    end

    def chunk_output
      if rolled_up?
        output
      else
        chunks.pluck(:text).join
      end
    end

    def schedule_rollup_chunks
      ChunkRollupJob.perform_later(self)
    end

    def rollup_chunks
      ActiveRecord::Base.transaction do
        self.output = chunk_output
        chunks.delete_all
        update_attribute(:rolled_up, true)
      end
    end

    def output
      gzip = self[:gzip_output]

      if gzip.blank?
        ''
      else
        ActiveSupport::Gzip.decompress(gzip)
      end
    end

    def output=(string)
      self[:gzip_output] = ActiveSupport::Gzip.compress(string)
    end

    def rollback?
      false
    end

    def rollbackable?
      false
    end

    def supports_rollback?
      false
    end

    def title
      definition.render_title(env)
    end

    def author
      user || AnonymousUser.new
    end

    def finished?
      !pending? && !running? && !aborting?
    end

    def ping
      Shipit.redis.set(status_key, 'alive', ex: PRESENCE_CHECK_TIMEOUT)
    end

    def alive?
      Shipit.redis.get(status_key) == 'alive'
    end

    def report_dead!
      write("ERROR: Background job hasn't reported back in #{PRESENCE_CHECK_TIMEOUT} seconds.")
      error!
    end

    def should_abort?
      @last_abort_count ||= 1
      (@last_abort_count..Shipit.redis.get(abort_key).to_i).each do |count|
        @last_abort_count = count + 1
        yield count
      end
    end

    def request_abort
      Shipit.redis.pipelined do
        Shipit.redis.incr(abort_key)
        Shipit.redis.expire(abort_key, 1.month.to_i)
      end
    end

    def abort!(rollback_once_aborted: false, aborted_by:)
      update!(rollback_once_aborted: rollback_once_aborted, aborted_by_id: aborted_by.id)

      if alive?
        aborting
        request_abort
      elsif aborting? || aborted?
        aborted
      elsif !finished?
        report_dead!
      end
    end

    def working_directory
      File.join(stack.deploys_path, id.to_s)
    end

    if Rails.gem_version >= Gem::Version.new('5.1.0.beta1')
      def record_status_change
        @status_changed ||= saved_change_to_attribute?(:status)
      end
    else
      def record_status_change
        @status_changed ||= status_changed?
      end
    end

    def emit_hooks
      return unless @status_changed
      @status_changed = nil
      Hook.emit(hook_event, stack, hook_event => self, status: status, stack: stack)
    end

    def hook_event
      self.class.name.demodulize.underscore.to_sym
    end

    def permalink
      Shipit::Engine.routes.url_helpers.stack_task_url(stack, self)
    end

    private

    def prevent_concurrency
      raise ConcurrentTaskRunning if stack.tasks.active.exclusive.count > 1
    end

    def status_key
      "shipit:task:#{id}"
    end

    def abort_key
      "#{status_key}:aborting"
    end
  end
end
