# frozen_string_literal: true

module DiscourseCodeReview
  class CodeReviewController < ::ApplicationController
    before_action :ensure_logged_in
    before_action :ensure_staff

    skip_before_action :verify_authenticity_token, only: :webhook
    skip_before_action :ensure_logged_in, only: :webhook
    skip_before_action :ensure_staff, only: :webhook
    skip_before_action :redirect_to_login_if_required, only: :webhook
    skip_before_action :check_xhr, only: [:webhook, :redirect]

    def webhook

      if SiteSetting.code_review_github_webhook_secret.blank?
        Rails.logger.warn("Make sure you set a secret up in code_review_github_webhook_secret")
        raise Discourse::InvalidAccess
      end

      request.body.rewind
      body = request.body.read
      signature = OpenSSL::HMAC.hexdigest(OpenSSL::Digest.new('sha1'), SiteSetting.code_review_github_webhook_secret, body)

      if !Rack::Utils.secure_compare("sha1=#{signature}", request.env['HTTP_X_HUB_SIGNATURE'])
        raise Discourse::InvalidAccess
      end

      type = request.env['HTTP_X_GITHUB_EVENT']

      # unique hash for webhook
      # delivery = request.env['HTTP_X_GITHUB_DELIVERY']

      repo = params["repository"]
      repo_name = repo["full_name"] if repo

      if type == "commit_comment"
        commit_sha = params["comment"]["commit_id"]

        ::Jobs.enqueue(
          :code_review_sync_commit_comments,
          repo_name: repo_name,
          commit_sha: commit_sha,
        )
      end

      if type == "push"
        ::Jobs.enqueue(:code_review_sync_commits, repo_name: repo_name)
      end

      if type == "commit_comment"
        syncer = DiscourseCodeReview.github_pr_syncer
        git_commit = params["comment"]["commit_id"]

        syncer.sync_associated_pull_requests(repo_name, git_commit)
      end

      if ["pull_request", "issue_comment", "pull_request_review", "pull_request_review_comment"].include? type
        syncer = DiscourseCodeReview.github_pr_syncer

        issue_number =
          params['number'] ||
          (params['issue'] && params['issue']['number']) ||
          (params['pull_request'] && params['pull_request']['number'])

        syncer.sync_pull_request(repo_name, issue_number)
      end

      render plain: '"ok"'
    end

    def skip
      topic = Topic.find_by(id: params[:topic_id])

      State::CommitApproval.skip(
        topic,
        current_user
      )

      render_next_topic(topic.category_id)
    end

    def followup
      if !SiteSetting.code_review_allow_manual_followup
        raise Discourse::InvalidAccess
      end

      topic = Topic.find_by(id: params[:topic_id])

      State::CommitApproval.followup(
        topic,
        current_user
      )

      render_next_topic(topic.category_id)
    end

    def approve
      topic = Topic.find_by(id: params[:topic_id])

      if !SiteSetting.code_review_allow_self_approval && topic.user_id == current_user.id
        raise Discourse::InvalidAccess
      end

      State::CommitApproval.approve(
        topic,
        [current_user]
      )

      render_next_topic(topic.category_id)
    end

    def redirect
      sha1 = params[:sha1]

      if sha1.present? && sha1.size >= 7
        tcf = TopicCustomField
          .where(name: DiscourseCodeReview::COMMIT_HASH)
          .where("LEFT(LOWER(value), :len) = LOWER(:sha1)", len: sha1.size, sha1: sha1)
          .order("created_at DESC")
          .includes(:topic)
          .first
      end

      raise Discourse::NotFound.new if tcf.blank?
      guardian.ensure_can_see!(tcf.topic)

      redirect_to tcf.topic.url
    end

    protected

    def render_next_topic(category_id)

      category_filter_sql = <<~SQL
        category_id NOT IN (
          SELECT category_id
          FROM category_users
          WHERE user_id = :user_id AND
            notification_level = :notification_level AND
            category_id <> :requested_category_id
        )
      SQL

      sanitized_join =
        ActiveRecord::Base.send(
          :sanitize_sql_array,
          [
            "LEFT OUTER JOIN skipped_code_reviews cr ON cr.topic_id = topics.id AND cr.user_id = ? and cr.expires_at > ?",
            current_user.id,
            Time.zone.now
          ]
        )

      next_topic = Topic
        .joins(:tags)
        .joins("LEFT OUTER JOIN topic_users ON (topics.id = topic_users.topic_id AND topic_users.user_id = #{current_user.id})")
        .joins(sanitized_join)
        .where('tags.name = ?', SiteSetting.code_review_pending_tag)
        .where('topics.user_id <> ?', current_user.id)
        .where(
          category_filter_sql,
          user_id: current_user.id,
          notification_level: CategoryUser.notification_levels[:muted],
          requested_category_id: category_id
        )
        .order(
          'case when cr.expires_at IS NULL then 0 else 1 end asc',
          'case when last_read_post_number IS NULL then 0 else 1 end asc',
          "case when category_id = #{category_id.to_i} then 0 else 1 end asc",
          'bumped_at desc'
        )
        .first

      url = next_topic&.relative_url

      render json: {
        next_topic_url: url
      }
    end

  end
end
