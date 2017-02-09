require 'test_helper'

module Shipit
  class MergePullRequestsJobTest < ActiveSupport::TestCase
    setup do
      @stack = shipit_stacks(:shipit)
      @job = MergePullRequestsJob.new

      @pending_pr = shipit_pull_requests(:shipit_pending)
      @unmergeable_pr = shipit_pull_requests(:shipit_pending_unmergeable)
      @not_ready_pr = shipit_pull_requests(:shipit_pending_not_mergeable_yet)
    end

    test "#perform rejects unmergeable PRs and merge the others" do
      PullRequest.any_instance.stubs(:refresh!)
      FakeWeb.register_uri(:put, "#{@pending_pr.api_url}/merge", status: %w(200 OK), body: {
        sha: "6dcb09b5b57875f334f61aebed695e2e4193db5e",
        merged: true,
        message: "Pull Request successfully merged",
      }.to_json)
      branch_url = "https://api.github.com/repos/shopify/shipit-engine/git/refs/heads/feature-62"
      FakeWeb.register_uri(:delete, branch_url, status: %w(204 No content))

      @job.perform(@stack)

      assert_predicate @pending_pr.reload, :merged?
      assert_predicate @unmergeable_pr.reload, :rejected?
    end

    test "#perform rejects PRs if the merge attempt fails" do
      PullRequest.any_instance.stubs(:refresh!)
      FakeWeb.register_uri(:put, "#{@pending_pr.api_url}/merge", status: %w(405 Method not allowed), body: {
        message: "Pull Request is not mergeable",
        documentation_url: "https://developer.github.com/v3/pulls/#merge-a-pull-request-merge-button",
      }.to_json)

      @job.perform(@stack)

      assert_predicate @pending_pr.reload, :rejected?
    end

    test "perform rejects PRs but do not attempt to merge any if the stack doesn't allow merges" do
      PullRequest.any_instance.stubs(:refresh!)
      @stack.update!(lock_reason: 'Maintenance')
      @job.perform(@stack)
      assert_predicate @pending_pr.reload, :pending?
    end
  end
end
