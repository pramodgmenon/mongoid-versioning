# encoding: utf-8
require "mongoid"
require "mongoid/errors/versioning_not_on_root"
require "mongoid/versioning/monkey_patches"

module Mongoid

  # Include this module to get automatic versioning of root level documents.
  # This will add a version field to the +Document+ and a has_many association
  # with all the versions contained in it.
  module Versioning
    extend ActiveSupport::Concern

    included do
      field :version, type: Integer, default: 1

      embeds_many \
        :versions,
        class_name: self.name,
        validate: false,
        cyclic: true,
        inverse_of: nil,
        versioned: true

      set_callback :save, :before, :revise, if: :revisable?

      class_attribute :version_max
      self.cyclic = true
    end

    # Create a new version of the +Document+. This will load the previous
    # document from the database and set it as the next version before saving
    # the current document. It then increments the version number. If a #max_versions
    # limit is set in the model and it's exceeded, the oldest version gets discarded.
    #
    # @example Revise the document.
    #   person.revise
    #
    # @since 1.0.0
    def revise
      previous = previous_revision
      if previous && versioned_attributes_changed?
        new_version = versions.build(previous.versioned_attributes)
        new_version._id = nil
        if version_max.present? && versions.length > version_max
          deleted = versions.first
          versions.delete(deleted)
        end
        self.version = (version || 1 ) + 1
      end
    end

    # Forces the creation of a new version of the +Document+, regardless of
    # whether a change was actually made.
    #
    # @example Revise the document.
    #   person.revise!
    #
    # @since 2.2.1
    def revise!
      versions.build(
        (previous_revision || self).versioned_attributes
      )
      versions.shift if version_max.present? && versions.length > version_max
      self.version = (version || 1 ) + 1
      save
    end

    # Filters the results of +changes+ by removing any fields that should
    # not be versioned.
    #
    # @return [ Hash ] A hash of versioned changed attributes.
    #
    # @since 2.1.0
    def versioned_changes
      only_versioned_attributes(changes.except("updated_at"))
    end

    # Filters the results of +attributes+ by removing any fields that should
    # not be versioned.
    #
    # @return [ Hash ] A hash of versioned attributes.
    #
    # @since 2.1.0
    def versioned_attributes
      only_versioned_attributes(attributes)
    end

    # Check if any versioned fields have been modified. This is similar
    # to +changed?+, except this method also ignores fields set to be
    # ignored by versioning.
    #
    # @return [ Boolean ] Whether fields that will be versioned have changed.
    #
    # @since 2.1.0
    def versioned_attributes_changed?
      !versioned_changes.empty?
    end

    # Executes a block that temporarily disables versioning. This is for cases
    # where you do not want to version on every save.
    #
    # @example Execute a save without versioning.
    #   person.versionless(&:save)
    #
    # @return [ Object ] The document or result of the block execution.
    #
    # @since 2.0.0
    def versionless
      @versionless = true
      result = yield(self) if block_given?
      @versionless = false
      result || self
    end

    private

    def clone_document
      attrs = as_document.__deep_copy__
      attrs["version"] = 1 if attrs.delete("versions")
      process_localized_attributes(attrs)
      attrs
    end

    # Find the previous version of this document in the database, or if the
    # document had been saved without versioning return the persisted one.
    #
    # @example Find the last version.
    #   document.find_last_version
    #
    # @return [ Document, nil ] The previously saved document.
    #
    # @since 2.0.0
    def previous_revision
      _loading_revision do
        self.class.unscoped.
          with(self.mongo_session.options).
          where(_id: id).
          any_of({ version: version }, { version: nil }).first
      end
    end

    # Is the document able to be revised? This is true if the document has
    # changed and we have not explicitly told it not to version.
    #
    # @example Is the document revisable?
    #   document.revisable?
    #
    # @return [ true, false ] If the document is revisable.
    #
    # @since 2.0.0
    def revisable?
      versioned_attributes_changed? && !versionless?
    end

    # Are we in versionless mode? This is true if in a versionless block on the
    # document.
    #
    # @example Is the document in versionless mode?
    #   document.versionless?
    #
    # @return [ true, false ] Is the document not currently versioning.
    #
    # @since 2.0.0
    def versionless?
      @versionless ||= false
    end

    # Filters fields that should not be versioned out of an attributes hash.
    # Dynamic attributes are always versioned.
    #
    # @param [ Hash ] A hash with field names as keys.
    #
    # @return [ Hash ] The hash without non-versioned columns.
    #
    # @since 2.1.0
    def only_versioned_attributes(hash)
      versioned = {}
      hash.except("versions").each_pair do |name, value|
        add_versioned_attribute(versioned, name, value)
      end
      versioned
    end

    # Add the versioned attribute. Will work now for localized fields.
    #
    # @api private
    #
    # @example Add the versioned attribute.
    #   model.add_versioned_attribute({}, "name", "test")
    #
    # @param [ Hash ] versioned The versioned attributes.
    # @param [ String ] name The name of the field.
    # @param [ Object ] value The value for the field.
    #
    # @since 3.0.10
    def add_versioned_attribute(versioned, name, value)
      field = fields[name]
      if field && field.localized?
        versioned["#{name}_translations"] = value
      else
        versioned[name] = value if !field || field.versioned?
      end
    end

    module ClassMethods

      # Sets the maximum number of versions to store.
      #
      # @example Set the maximum.
      #   Person.max_versions(5)
      #
      # @param [ Integer ] number The maximum number to store.
      #
      # @return [ Integer ] The max number of versions.
      def max_versions(number)
        self.version_max = number.to_i
      end
    end
  end
end
