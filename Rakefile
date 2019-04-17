# Add your own tasks in files placed in lib/tasks ending in .rake,
# for example lib/tasks/capistrano.rake, and they will automatically be available to Rake.

begin
  require 'rubocop/rake_task'
  RuboCop::RakeTask.new
rescue LoadError
end

APP_RAKEFILE = File.expand_path('../test/dummy/Rakefile', __FILE__)
load 'rails/tasks/engine.rake'

Bundler::GemHelper.install_tasks

require 'rake/testtask'

Rake::TestTask.new(:test) do |t|
  t.libs << 'lib'
  t.libs << 'test'
  t.test_files = FileList.new('test/**/*_test.rb').exclude('test/dummy/**/*')
  t.verbose = false
end

task default: :test

desc "Deploy from a running instance. "
task :deploy, %i(stack revision) => :environment do |_t, args|
  begin
    args.with_defaults(stack: nil, revision: nil)

    stack = args[:stack]
    revision = args[:revision]

    raise ArgumentError.new('The first argument has to be a stack, e.g. shopify/shipit/production') if stack.nil?
    raise ArgumentError.new('The second argument has to be a revision') if revision.nil?

    module Shipit
      class Task
        def write(text)
          p text
          chunks.create!(text: text)
        end
      end
    end

    Shipit::Stack.run_deploy_in_foreground(stack: stack, revision: revision)
  rescue ArgumentError
    p "Use this command as follows:"
    p "bundle exec rake deploy\['shopify/shipit/production','593b1f07cec6c30df3f62d9e63b31dc0ff444098'\]"
    raise
  end
end
