# frozen_string_literal: true

# An Ignition Group legal entity that uses IGSIGN to sign commercial agreements.
# The `key` field is a short snake_case identifier (e.g. "iti", "spot_connect")
# used throughout the codebase as the stable reference — never change an existing key.
class IgEntity < ApplicationRecord
  has_many :ig_entity_signatories, dependent: :destroy
  has_many :ig_signatories, through: :ig_entity_signatories

  validates :key,  presence: true, uniqueness: true
  validates :name, presence: true

  scope :active, -> { where(active: true) }
  scope :ordered, -> { order(:name) }

  # Returns the short display name (e.g. "ITI") or falls back to full name.
  def short_name
    display_name.presence || name
  end

  # Legacy hash-style access so callers migrated from ENTITIES[key] work
  # with both the old hash keys and new model attributes.
  def [](key)
    case key.to_sym
    when :name        then name
    when :short_name  then short_name
    when :registration, :registration_number then registration_number
    when :address, :registered_address       then registered_address
    when :key                                then self.key
    end
  end
end
