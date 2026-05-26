# frozen_string_literal: true

# Join record: one person playing one role for one entity.
# A person may have multiple rows for the same entity if they hold multiple positions
# (e.g. Laren Farquharson is both bu_cfo for ITI and group_cfo for every entity).
class IgEntitySignatory < ApplicationRecord
  belongs_to :ig_entity
  belongs_to :ig_signatory

  validates :position, presence: true,
                       inclusion: { in: IgSignatory::POSITIONS }
  validates :ig_signatory_id, uniqueness: {
    scope:   %i[ig_entity_id position],
    message: 'already assigned to this entity + position'
  }

  scope :active,   -> { where(active: true) }
  scope :for_position, ->(pos) { where(position: pos) }
  scope :ordered,  -> { order(:id) }
end
