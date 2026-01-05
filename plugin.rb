# frozen_string_literal: true

# name: discourse-deald-feedback
# about: User feedback and rating system for DEALD marketplace
# version: 1.0.0
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

  # Create feedbacks table if not exists
  unless ActiveRecord::Base.connection.table_exists?(:deald_feedbacks)
    ActiveRecord::Base.connection.create_table :deald_feedbacks do |t|
      t.integer :author_id, null: false
      t.integer :recipient_id, null: false
      t.integer :rating, null: false
      t.text :comment
      t.string :ticket_number, null: false
      t.boolean :disputed, default: false
      t.text :dispute_reason
      t.datetime :disputed_at
      t.integer :resolved_by_id
      t.datetime :resolved_at
      t.string :resolution_status
      t.timestamps
    end
    
    ActiveRecord::Base.connection.add_index :deald_feedbacks, :author_id
    ActiveRecord::Base.connection.add_index :deald_feedbacks, :recipient_id
    ActiveRecord::Base.connection.add_index :deald_feedbacks, :ticket_number
    ActiveRecord::Base.connection.add_index :deald_feedbacks, [:author_id, :recipient_id, :ticket_number], unique: true, name: 'idx_feedback_unique'
  end

  # Model
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
    
    validate :author_cannot_be_recipient
    validate :unique_feedback_per_ticket
    
    scope :for_user, ->(user_id) { where(recipient_id: user_id) }
    scope :by_user, ->(user_id) { where(author_id: user_id) }
    scope :disputed, -> { where(disputed: true, resolution_status: nil) }
    scope :resolved, -> { where.not(resolution_status: nil) }
    
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
      update!(
        disputed: true,
        dispute_reason: reason,
        disputed_at: Time.current
      )
    end
    
    def resolve!(admin, status)
      update!(
        resolved_by_id: admin.id,
        resolved_at: Time.current,
        resolution_status: status
      )
    end
    
    private
    
    def author_cannot_be_recipient
      if author_id == recipient_id
        errors.add(:base, I18n.t("deald_feedback.errors.cannot_feedback_self"))
      end
    end
    
    def unique_feedback_per_ticket
      existing = DealdFeedback::Feedback.where(
        author_id: author_id,
        recipient_id: recipient_id,
        ticket_number: ticket_number
      ).where.not(id: id).exists?
      
      if existing
        errors.add(:base, I18n.t("deald_feedback.errors.already_left_feedback"))
      end
    end
  end

  # Controller
  class ::DealdFeedback::FeedbackController < ::ApplicationController
    requires_plugin DealdFeedback::PLUGIN_NAME
    before_action :ensure_logged_in, except: [:index, :show]
    
    def index
      user = User.find_by(username: params[:username])
      raise Discourse::NotFound unless user
      
      feedbacks = DealdFeedback::Feedback.for_user(user.id)
        .includes(:author)
        .order(created_at: :desc)
      
      render json: {
        feedbacks: feedbacks.map { |f| serialize_feedback(f) },
        stats: calculate_stats(user.id),
        can_leave_feedback: can_leave_feedback?(user)
      }
    end
    
    def show
      feedback = DealdFeedback::Feedback.find(params[:id])
      render json: { feedback: serialize_feedback(feedback) }
    end
    
    def create
      recipient = User.find_by(username: params[:username])
      raise Discourse::NotFound unless recipient
      
      raise Discourse::InvalidAccess.new(I18n.t("deald_feedback.errors.cannot_feedback_self")) if current_user.id == recipient.id
      raise Discourse::InvalidAccess.new(I18n.t("deald_feedback.errors.cannot_feedback_admin")) if recipient.admin? && !SiteSetting.deald_feedback_allow_on_admins
      
      feedback = DealdFeedback::Feedback.create!(
        author_id: current_user.id,
        recipient_id: recipient.id,
        rating: params[:rating].to_i,
        comment: params[:comment],
        ticket_number: params[:ticket_number]
      )
      
      render json: { feedback: serialize_feedback(feedback) }
    end
    
    def destroy
      feedback = DealdFeedback::Feedback.find(params[:id])
      
      unless current_user.admin? || (feedback.author_id == current_user.id && within_edit_window?(feedback))
        raise Discourse::InvalidAccess.new(I18n.t("deald_feedback.errors.not_authorized"))
      end
      
      feedback.destroy!
      render json: { success: true }
    end
    
    def dispute
      feedback = DealdFeedback::Feedback.find(params[:id])
      
      unless feedback.recipient_id == current_user.id
        raise Discourse::InvalidAccess.new(I18n.t("deald_feedback.errors.not_authorized"))
      end
      
      feedback.dispute!(params[:reason])
      render json: { feedback: serialize_feedback(feedback) }
    end
    
    def resolve
      raise Discourse::InvalidAccess unless current_user.admin?
      
      feedback = DealdFeedback::Feedback.find(params[:id])
      feedback.resolve!(current_user, params[:status])
      render json: { feedback: serialize_feedback(feedback) }
    end
    
    private
    
    def serialize_feedback(feedback)
      {
        id: feedback.id,
        author: {
          id: feedback.author.id,
          username: feedback.author.username,
          avatar_template: feedback.author.avatar_template
        },
        rating: feedback.rating,
        comment: feedback.comment,
        ticket_number: feedback.ticket_number,
        disputed: feedback.disputed,
        dispute_reason: feedback.dispute_reason,
        disputed_at: feedback.disputed_at,
        resolution_status: feedback.resolution_status,
        resolved_at: feedback.resolved_at,
        created_at: feedback.created_at,
        can_edit: can_edit?(feedback),
        can_delete: can_delete?(feedback),
        can_dispute: can_dispute?(feedback)
      }
    end
    
    def calculate_stats(user_id)
      feedbacks = DealdFeedback::Feedback.for_user(user_id)
      {
        total: feedbacks.count,
        positive: feedbacks.where(rating: 4..5).count,
        neutral: feedbacks.where(rating: 3).count,
        negative: feedbacks.where(rating: 1..2).count,
        average: feedbacks.average(:rating)&.round(1) || 0,
        disputed_pending: feedbacks.disputed.count
      }
    end
    
    def can_leave_feedback?(user)
      return false unless current_user
      return false if current_user.id == user.id
      return false if user.admin? && !SiteSetting.deald_feedback_allow_on_admins
      true
    end
    
    def can_edit?(feedback)
      return true if current_user&.admin?
      return false unless current_user
      feedback.author_id == current_user.id && within_edit_window?(feedback)
    end
    
    def can_delete?(feedback)
      return true if current_user&.admin?
      return false unless current_user
      feedback.author_id == current_user.id && within_edit_window?(feedback)
    end
    
    def can_dispute?(feedback)
      return false unless current_user
      return false if feedback.disputed
      feedback.recipient_id == current_user.id
    end
    
    def within_edit_window?(feedback)
      hours = SiteSetting.deald_feedback_edit_window_hours
      return true if hours == 0
      feedback.created_at > hours.hours.ago
    end
  end

  # Routes
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

  # Add to user card serializer
  add_to_serializer(:user_card, :feedback_stats) do
    feedbacks = DealdFeedback::Feedback.where(recipient_id: object.id)
    {
      total: feedbacks.count,
      positive: feedbacks.where(rating: 4..5).count,
      neutral: feedbacks.where(rating: 3).count,
      negative: feedbacks.where(rating: 1..2).count,
      average: feedbacks.average(:rating)&.round(1) || 0
    }
  end

end
