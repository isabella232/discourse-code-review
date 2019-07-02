# frozen_string_literal: true

module DiscourseCodeReview
  class GithubUserSyncer
    def ensure_user(name:, email: nil, github_login: nil, github_id: nil)
      user = nil

      user ||=
        if github_id
            User.find_by(
              id:
                UserCustomField
                  .select(:user_id)
                  .where(name: GithubId, value: github_id)
                  .limit(1)
            )
        end

      user ||=
        if github_login
          user =
            User.find_by(
              id:
                UserCustomField
                  .select(:user_id)
                  .where(name: GithubLogin, value: github_login)
                  .limit(1)
            )
        end

      user ||= begin
        email ||= email_for(github_login)

        User.find_by_email(email)
      end

      user ||= begin
        username = UserNameSuggester.sanitize_username(github_login || name)

        User.create!(
          email: email,
          username: UserNameSuggester.suggest(username.presence || email),
          name: name.presence || User.suggest_name(email),
          staged: true
        )
      end

      if github_login
        rel = UserCustomField.where(name: GithubLogin, value: github_login)
        existing = rel.pluck(:user_id)

        if existing != [user.id]
          rel.destroy_all
          UserCustomField.create!(name: GithubLogin, value: github_login, user_id: user.id)
        end
      end

      if github_id

        rel = UserCustomField.where(name: GithubId, value: github_id)
        existing = rel.pluck(:user_id)

        if existing != [user.id]
          rel.destroy_all
          UserCustomField.create!(name: GithubId, value: github_id, user_id: user.id)
        end
      end
      user
    end

    private

    def email_for(github_login)
      "#{github_login}@fake.github.com"
    end
  end
end
