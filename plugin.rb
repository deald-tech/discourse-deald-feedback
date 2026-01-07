# frozen_string_literal: true

# name: discourse-deald-feedback
# about: User feedback and rating system for DEALD marketplace
# version: 1.4.0
# authors: DEALD
# url: https://github.com/deald-tech/discourse-deald-feedback

enabled_site_setting :deald_feedback_enabled

register_asset "stylesheets/feedback.scss"

after_initialize do
  
  module ::DealdFeedback
    PLUGIN_NAME = "discourse-deald-feedback"
    
    class Engine < ::Rails::Engine
      engine_name PLUGIN_NAME
      isolate_namespace DealdFeedback
    end
    
    class Error < StandardError; end
  end

  unless ActiveRecord::Base.connection.table_exists?(:deald_feedbacks)
    ActiveRecord::Base.connection.create_table :deald_feedbacks do |t|
      t.integer :author_id, null: false
      t.integer :recipient_id, null: false
      t.integer :rating, null: false
      t.text :comment
      t.string :ticket_number, null: false
      t.string :role, default: "buyer"
      t.boolean :disputed, default: false
      t.text :dispute_reason
      t.datetime :disputed_at
      t.integer :resolved_by_id
      t.datetime :resolved_at
      t.string :resolution_status
      t.boolean :was_disputed, default: false
      t.timestamps
    end
    
    ActiveRecord::Base.connection.add_index :deald_feedbacks, :author_id
    ActiveRecord::Base.connection.add_index :deald_feedbacks, :recipient_id
    ActiveRecord::Base.connection.add_index :deald_feedbacks, :ticket_number
    ActiveRecord::Base.connection.add_index :deald_feedbacks, [:author_id, :recipient_id, :ticket_number], unique: true, name: 'idx_feedback_unique'
  end

  unless ActiveRecord::Base.connection.column_exists?(:deald_feedbacks, :role)
    ActiveRecord::Base.connection.add_column :deald_feedbacks, :role, :string, default: "buyer"
  end
  
  unless ActiveRecord::Base.connection.column_exists?(:deald_feedbacks, :was_disputed)
    ActiveRecord::Base.connection.add_column :deald_feedbacks, :was_disputed, :boolean, default: false
  end

  class ::DealdFeedback::Feedback < ActiveRecord::Base
    self.table_name = "deald_feedbacks"
    
    belongs_to :author, class_name: "User", foreign_key: :author_id
    belongs_to :recipient, class_name: "User", foreign_key: :recipient_id
    belongs_to :resolved_by, class_name: "User", foreign_key: :resolved_by_id, optional: true
    
    validates :author_id, presence: true
    validates :recipient_id, presence: true
    validates :rating, presence: true, inclusion: { in: 1..5 }
    validates :ticket_number, presence: true
    validates :comment, length: { maximum: 1000 }
    validates :role, inclusion: { in: %w[buyer seller] }, allow_nil: true
    
    validate :author_cannot_be_recipient
    validate :unique_feedback_per_ticket
    
    scope :for_user, ->(user_id) { where(recipient_id: user_id) }
    scope :by_user, ->(user_id) { where(author_id: user_id) }
    scope :disputed, -> { where(disputed: true, resolution_status: nil) }
    scope :resolved, -> { where.not(resolution_status: nil) }
    scope :as_buyer, -> { where(role: "buyer") }
    scope :as_seller, -> { where(role: "seller") }
    
    after_create :notify_recipient_of_feedback
    
    def positive?
      rating >= 4
    end
    
    def neutral?
      rating == 3
    end
    
    def negative?
      rating <= 2
    end
    
    def dispute!(reason)
      return false if was_disputed
      update!(disputed: true, dispute_reason: reason, disputed_at: Time.current)
    end
    
    def resolve!(admin, status)
      if status == "accepted"
        notify_dispute_resolved!("accepted")
        destroy!
      else
        update!(disputed: false, resolved_by_id: admin.id, resolved_at: Time.current, resolution_status: status, was_disputed: true)
        notify_dispute_resolved!("rejected")
      end
    end
    
    def notify_recipient_of_feedback
      PostCreator.create!(Discourse.system_user, title: "New Feedback Received - Ticket #{ticket_number}", raw: "Hello @#{recipient.username},\n\nYou have received new feedback from @#{author.username}.\n\n**Rating:** #{rating}/5 stars\n**Role:** #{role&.capitalize || 'Buyer'}\n**Ticket:** #{ticket_number}\n**Comment:** #{comment.presence || '(no comment)'}\n\nYou can view your feedback at: /u/#{recipient.username}\n\nIf you believe this feedback is unfair, you can dispute it from your profile.", archetype: Archetype.private_message, target_usernames: recipient.username, skip_validations: true)
    rescue => e
      Rails.logger.error("Failed to notify feedback recipient: #{e.message}")
    end
    
    def notify_dispute_resolved!(status)
      message = status == "accepted" ? "Your dispute has been **accepted**. The feedback has been removed from your profile." : "Your dispute has been **rejected**. The feedback will remain on your profile. This feedback cannot be disputed again."
      PostCreator.create!(Discourse.system_user, title: "Feedback Dispute Resolved - Ticket #{ticket_number}", raw: "Hello @#{recipient.username},\n\n#{message}\n\n**Original Feedback:**\n- From: @#{author.username}\n- Rating: #{rating}/5 stars\n- Ticket: #{ticket_number}\n- Comment: #{comment.presence || '(no comment)'}\n\nIf you have any questions, please contact an administrator.", archetype: Archetype.private_message, target_usernames: recipient.username, skip_validations: true)
    rescue => e
      Rails.logger.error("Failed to notify dispute resolution: #{e.message}")
    end
    
    private
    
    def author_cannot_be_recipient
      errors.add(:base, "Cannot leave feedback for yourself") if author_id == recipient_id
    end
    
    def unique_feedback_per_ticket
      existing = DealdFeedback::Feedback.where(author_id: author_id, recipient_id: recipient_id, ticket_number: ticket_number).where.not(id: id).exists?
      errors.add(:base, "Already left feedback for this ticket") if existing
    end
  end

  class ::DealdFeedback::FeedbackController < ::ApplicationController
    requires_plugin DealdFeedback::PLUGIN_NAME
    before_action :ensure_logged_in, except: [:index, :show]
    skip_before_action :verify_authenticity_token, only: [:create, :destroy, :dispute, :resolve]
    
    def index
      user = User.find_by(username: params[:username])
      raise Discourse::NotFound unless user
      feedbacks = DealdFeedback::Feedback.for_user(user.id).includes(:author).order(created_at: :desc)
      render json: { feedbacks: feedbacks.map { |f| serialize_feedback(f) }, stats: calculate_stats(user.id), can_leave_feedback: can_leave_feedback?(user) }
    end
    
    def show
      feedback = DealdFeedback::Feedback.find(params[:id])
      render json: { feedback: serialize_feedback(feedback) }
    end
    
    def create
      recipient = User.find_by(username: params[:username])
      raise Discourse::NotFound unless recipient
      raise Discourse::InvalidAccess.new("Cannot leave feedback for yourself") if current_user.id == recipient.id
      raise Discourse::InvalidAccess.new("Cannot leave feedback for admin") if recipient.admin?
      role_param = params[:role] || params.dig(:feedback, :role)
      role_value = role_param.to_s.downcase.strip
      role_value = "buyer" unless %w[buyer seller].include?(role_value)
      feedback = DealdFeedback::Feedback.create!(author_id: current_user.id, recipient_id: recipient.id, rating: params[:rating].to_i, comment: params[:comment], ticket_number: params[:ticket_number], role: role_value)
      render json: { feedback: serialize_feedback(feedback) }
    end
    
    def destroy
      feedback = DealdFeedback::Feedback.find(params[:id])
      unless current_user.admin? || feedback.author_id == current_user.id
        raise Discourse::InvalidAccess.new("Not authorized")
      end
      feedback.destroy!
      render json: { success: true }
    end
    
    def dispute
      feedback = DealdFeedback::Feedback.find(params[:id])
      unless feedback.recipient_id == current_user.id
        raise Discourse::InvalidAccess.new("Not authorized")
      end
      if feedback.was_disputed
        render json: { error: "This feedback has already been disputed and cannot be disputed again." }, status: 422
        return
      end
      feedback.dispute!(params[:reason])
      render json: { feedback: serialize_feedback(feedback) }
    end
    
    def resolve
      raise Discourse::InvalidAccess unless current_user.admin?
      feedback = DealdFeedback::Feedback.find(params[:id])
      status = params[:status]
      unless %w[accepted rejected].include?(status)
        render json: { error: "Invalid status" }, status: 422
        return
      end
      feedback.resolve!(current_user, status)
      if status == "accepted"
        render json: { success: true, deleted: true }
      else
        render json: { feedback: serialize_feedback(feedback) }
      end
    end
    
    private
    
    def serialize_feedback(feedback)
      { id: feedback.id, author: { id: feedback.author.id, username: feedback.author.username, avatar_template: feedback.author.avatar_template }, rating: feedback.rating, comment: feedback.comment, ticket_number: feedback.ticket_number, role: feedback.role || "buyer", disputed: feedback.disputed, dispute_reason: feedback.dispute_reason, disputed_at: feedback.disputed_at, resolution_status: feedback.resolution_status, resolved_at: feedback.resolved_at, was_disputed: feedback.was_disputed, created_at: feedback.created_at, can_edit: can_edit?(feedback), can_delete: can_delete?(feedback), can_dispute: can_dispute?(feedback) }
    end
    
    def calculate_stats(user_id)
      feedbacks = DealdFeedback::Feedback.for_user(user_id)
      { total: feedbacks.count, positive: feedbacks.where(rating: 4..5).count, neutral: feedbacks.where(rating: 3).count, negative: feedbacks.where(rating: 1..2).count, average: feedbacks.average(:rating)&.round(1) || 0, disputed_pending: feedbacks.disputed.count }
    end
    
    def can_leave_feedback?(user)
      return false unless current_user
      return false if current_user.id == user.id
      return false if user.admin?
      true
    end
    
    def can_edit?(feedback)
      return true if current_user&.admin?
      return false unless current_user
      feedback.author_id == current_user.id
    end
    
    def can_delete?(feedback)
      return true if current_user&.admin?
      return false unless current_user
      feedback.author_id == current_user.id
    end
    
    def can_dispute?(feedback)
      return false unless current_user
      return false if feedback.disputed
      return false if feedback.was_disputed
      feedback.recipient_id == current_user.id
    end
  end

  DealdFeedback::Engine.routes.draw do
    get "/user/:username" => "feedback#index"
    get "/:id" => "feedback#show"
    post "/user/:username" => "feedback#create"
    delete "/:id" => "feedback#destroy"
    post "/:id/dispute" => "feedback#dispute"
    post "/:id/resolve" => "feedback#resolve"
  end

  Discourse::Application.routes.append do
    mount ::DealdFeedback::Engine, at: "/deald-feedback"
  end

  add_to_serializer(:user_card, :feedback_stats) do
    feedbacks = DealdFeedback::Feedback.where(recipient_id: object.id)
    { total: feedbacks.count, positive: feedbacks.where(rating: 4..5).count, neutral: feedbacks.where(rating: 3).count, negative: feedbacks.where(rating: 1..2).count, average: feedbacks.average(:rating)&.round(1) || 0 }
  end

end

