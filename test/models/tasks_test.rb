require 'test_helper'

module Shipit
  class TasksTest < ActiveSupport::TestCase
    test "#title interpolates env" do
      task = shipit_tasks(:shipit_rendered_failover)
      assert_equal({'POD_ID' => '12'}, task.env)
      assert_equal 'Failover pod 12', task.title
    end

    test "#title returns the task action if title is not defined" do
      task = shipit_tasks(:shipit_restart)
      assert_equal 'Restart application', task.title
    end

    test '#title returns an error message when the title raises an error' do
      task = shipit_tasks(:shipit_with_title_parsing_issue)
      assert_equal 'This task (title: Using the %{WRONG_VARIABLE_NAME}) cannot be shown due to an incorrect variable name. Check your shipit.yml file', task.title
    end

    test '#show_checklist? is false with no checklist and no show_checklist_on' do
      task = shipit_tasks(:shipit_restart)
      refute_predicate task, :show_checklist?
    end

    test '#show_checklist? is false when checklist present but disabled by show_checklist_on' do
      task = shipit_tasks(:shipit_restart)
      task.spec.stubs(:review_checklist).returns(%w(foo))
      task.spec.expects(:show_checklist_on).returns(%w(deploy)).at_least_once
      refute_predicate task, :show_checklist?
    end

    test '#show_checklist? is true when checklist present and enabled by show_checklist_on' do
      task = shipit_tasks(:shipit_restart)
      task.spec.stubs(:review_checklist).returns(%w(foo))
      task.spec.expects(:show_checklist_on).returns(%w(task)).at_least_once
      assert_predicate task, :show_checklist?
    end
  end
end
