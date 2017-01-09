module ScopedSearch

  # The QueryBuilder class builds an SQL query based on aquery string that is
  # provided to the search_for named scope. It uses a SearchDefinition instance
  # to shape the query.
  class QueryBuilder

    attr_reader :ast, :definition, :scoped_klass

    # Creates a find parameter hash that can be passed to ActiveRecord::Base#find,
    # given a search definition and query string. This method is called from the
    # search_for named scope.
    #
    # This method will parse the query string and build an SQL query using the search
    # query. It will return an empty hash if the search query is empty, in which case
    # the scope call will simply return all records.
    def self.build_query(definition, klass, query, options = {})
      query_builder_class = self.class_for(definition)

      raise ScopedSearch::QueryNotSupported, "Class #{klass.name} cannot be queried as it is abstract" if klass.abstract_class?

      query = ScopedSearch::QueryLanguage::Compiler.parse(query) if query.kind_of?(String)
      raise ArgumentError, "Unsupported query object: #{query.inspect}!" unless query.kind_of?(ScopedSearch::QueryLanguage::AST::Node)

      return query_builder_class.new(definition: definition,
                                     ast: query,
                                     profile: options[:profile],
                                     scoped_klass: klass).build_find_params(options)
    end

    # Loads the QueryBuilder class for the connection of the given definition.
    # If no specific adapter is found, the default QueryBuilder class is returned.
    def self.class_for(definition)
      case definition.klass.connection.class.name.split('::').last
      when /postgresql/i
        PostgreSQLAdapter
      else
        self
      end
    end

    # Initializes the instance by setting the relevant parameters
    def initialize(definition:, ast:, profile:, scoped_klass:)
      @definition = definition
      @ast = ast
      @definition.profile = profile
      @scoped_klass = scoped_klass
    end

    # Actually builds the find parameters hash that should be used in the search_for
    # named scope.
    def build_find_params(options)
      keyconditions = []
      keyparameters = []
      parameters = []
      includes   = []
      joins   = []

      # Build SQL WHERE clause using the AST
      sql = @ast.to_sql(self, definition) do |notification, value|

        # Handle the notifications encountered during the SQL generation:
        # Store the parameters, includes, etc so that they can be added to
        # the find-hash later on.
        case notification
          when :keycondition then keyconditions << value
          when :keyparameter then keyparameters << value
          when :parameter    then parameters    << value
          when :include      then includes      << value
          when :joins        then joins         << value
          else raise ScopedSearch::QueryNotSupported, "Cannot handle #{notification.inspect}: #{value.inspect}"
        end
      end
        # Build SQL ORDER BY clause
      order = order_by(options[:order]) do |notification, value|
        case notification
          when :parameter then parameters << value
          when :include   then includes   << value
          when :joins     then joins      << value
          else raise ScopedSearch::QueryNotSupported, "Cannot handle #{notification.inspect}: #{value.inspect}"
        end
      end
      sql = (keyconditions + (sql.blank? ? [] : [sql]) ).map {|c| "(#{c})"}.join(" AND ")
      # Build hash for ActiveRecord::Base#find for the named scope
      find_attributes = {}
      find_attributes[:conditions] = [sql] + keyparameters + parameters unless sql.blank?
      find_attributes[:include]    = includes.uniq                      unless includes.empty?
      find_attributes[:joins]      = joins.uniq                         unless joins.empty?
      find_attributes[:order]      = order                              unless order.nil?

      # p find_attributes # Uncomment for debugging
      return find_attributes
    end

    def find_field_def_for_order_by(order, &block)
      order ||= definition.default_order
      return [nil, nil] if order.blank?
      field_name, direction_name = order.to_s.split(/\s+/, 2)
      field_def = definition.field_by_name(field_name)
      raise ScopedSearch::QueryNotSupported, "the field '#{field_name}' in the order statement is not valid field for search" unless field_def
      return field_def, direction_name
    end

    def order_by(order, &block)
      field_def, direction_name = find_field_def_for_order_by(order, &block)
      return nil if field_def.nil?
      sql = field_def.to_field(scoped_klass).to_sql(&block)
      direction = (!direction_name.nil? && direction_name.downcase.eql?('desc')) ? " DESC" : " ASC"
      return sql + direction
    end

    # A hash that maps the operators of the query language with the corresponding SQL operator.
    SQL_OPERATORS = { :eq => '=',  :ne => '<>', :like => 'LIKE', :unlike => 'NOT LIKE',
                      :gt => '>',  :lt =>'<',   :lte => '<=',    :gte => '>=',
                      :in => 'IN', :notin => 'NOT IN' }

    # Return the SQL operator to use given an operator symbol and field definition.
    #
    # By default, it will simply look up the correct SQL operator in the SQL_OPERATORS
    # hash, but this can be overridden by a database adapter.
    def sql_operator(operator, field)
      raise ScopedSearch::QueryNotSupported, "the operator '#{operator}' is not supported for field type '#{field.type}'" if [:like, :unlike].include?(operator) and !field.textual?
      SQL_OPERATORS[operator]
    end

    # Returns a NOT (...)  SQL fragment that negates the current AST node's children
    def to_not_sql(rhs, definition, &block)
      "NOT COALESCE(#{rhs.to_sql(self, definition, &block)}, 0)"
    end

    # Perform a comparison between a field and a Date(Time) value.
    #
    # This function makes sure the date is valid and adjust the comparison in
    # some cases to return more logical results.
    #
    # This function needs a block that can be used to pass other information about the query
    # (parameters that should be escaped, includes) to the query builder.
    #
    # <tt>field_def</tt>:: The field definition to test.
    # <tt>operator</tt>:: The operator used for comparison.
    # <tt>value</tt>:: The value to compare the field with.
    def datetime_test(field_def, operator, value, &block) # :yields: finder_option_type, value
      field = field_def.to_field(scoped_klass)

      # Parse the value as a date/time and ignore invalid timestamps
      timestamp = definition.parse_temporal(value)
      return nil unless timestamp

      timestamp = timestamp.to_date if field.date?
      # Check for the case that a date-only value is given as search keyword,
      # but the field is of datetime type. Change the comparison to return
      # more logical results.
      if field.datetime?
        span = 1.minute if(value =~ /\A\s*\d+\s+\bminutes?\b\s+\bago\b\s*\z/i)
        span ||= (timestamp.day_fraction == 0) ? 1.day : 1.hour
        if [:eq, :ne].include?(operator)
          # Instead of looking for an exact (non-)match, look for dates that
          # fall inside/outside the range of timestamps of that day.
          yield(:parameter, timestamp)
          yield(:parameter, timestamp + span)
          negate    = (operator == :ne) ? 'NOT ' : ''
          field_sql = field.to_sql(operator, &block)
          return "#{negate}(#{field_sql} >= ? AND #{field_sql} < ?)"

        elsif operator == :gt
          # Make sure timestamps on the given date are not included in the results
          # by moving the date to the next day.
          timestamp += span
          operator = :gte

        elsif operator == :lte
          # Make sure the timestamps of the given date are included by moving the
          # date to the next date.
          timestamp += span
          operator = :lt
        end
      end

      # Yield the timestamp and return the SQL test
      yield(:parameter, timestamp)
      "#{field.to_sql(operator, &block)} #{sql_operator(operator, field)} ?"
    end

    # Validate the key name is in the set and translate the value to the set value.
    def translate_value(field_def, value)
      translated_value = field_def.complete_value[value.to_sym]
      raise ScopedSearch::QueryNotSupported, "'#{field_def.field}' should be one of '#{field_def.complete_value.keys.join(', ')}', but the query was '#{value}'" if translated_value.nil?
      translated_value
    end

    # A 'set' is group of possible values, for example a status might be "on", "off" or "unknown" and the database representation
    # could be for example a numeric value. This method will validate the input and translate it into the database representation.
    def set_test(field_def, operator,value, &block)
      set_value = translate_value(field_def, value)
      raise ScopedSearch::QueryNotSupported, "Operator '#{operator}' not supported for '#{field_def.field}'" unless [:eq,:ne].include?(operator)
      negate = ''
      if [true,false].include?(set_value)
        negate = 'NOT ' if operator == :ne
        if field_def.to_field(scoped_klass).numerical?
          operator =  (set_value == true) ?  :gt : :eq
          set_value = 0
        else
          operator = (set_value == true) ? :ne : :eq
          set_value = false
        end
      end
      yield(:parameter, set_value)
      return "#{negate}(#{field_def.to_field(scoped_klass).to_sql(operator, &block)} #{self.sql_operator(operator, field_def.to_field(scoped_klass))} ?)"
    end

    # Generates a simple SQL test expression, for a field and value using an operator.
    #
    # This function needs a block that can be used to pass other information about the query
    # (parameters that should be escaped, includes) to the query builder.
    #
    # <tt>field_def</tt>:: The field definition to test.
    # <tt>operator</tt>:: The operator used for comparison.
    # <tt>value</tt>:: The value to compare the field with.
    def sql_test(field_def, operator, value, lhs, &block) # :yields: finder_option_type, value
      field = field_def.to_field(scoped_klass)
      return field.to_ext_method_sql(lhs, sql_operator(operator, field), value, &block) if field_def.ext_method

      yield(:keyparameter, lhs.sub(/^.*\./,'')) if field_def.key_field

      if [:like, :unlike].include?(operator)
        yield(:parameter, (value !~ /^\%|\*/ && value !~ /\%|\*$/) ? "%#{value}%" : value.tr_s('%*', '%'))
        return "#{field.to_sql(operator, &block)} #{self.sql_operator(operator, field)} ?"

      elsif [:in, :notin].include?(operator)
        value.split(',').collect { |v| yield(:parameter, field_def.set? ? translate_value(field_def, v) : v.strip) }
        value = value.split(',').collect { "?" }.join(",")
        return "#{field.to_sql(operator, &block)} #{self.sql_operator(operator, field)} (#{value})"

      elsif field.temporal?
        return datetime_test(field_def, operator, value, &block)

      elsif field_def.set?
        return set_test(field_def, operator, value, &block)

      elsif field_def.relation && definition.reflection_by_name(scoped_klass, field_def.relation).macro == :has_many
        value = value.to_i if field_def.offset
        yield(:parameter, value)
        connection = scoped_klass.connection
        primary_key = "#{connection.quote_table_name(scoped_klass.table_name)}.#{connection.quote_column_name(scoped_klass.primary_key)}"
        if definition.reflection_by_name(scoped_klass, field_def.relation).options.has_key?(:through)
          join = has_many_through_join(field_def)
          return "#{primary_key} IN (SELECT #{primary_key} FROM #{join} WHERE #{field.to_sql(operator, &block)} #{self.sql_operator(operator, field)} ? )"
        else
          foreign_key = connection.quote_column_name(field.reflection_keys(definition.reflection_by_name(scoped_klass, field_def.relation))[1])
          return "#{primary_key} IN (SELECT #{foreign_key} FROM #{connection.quote_table_name(field.klass.table_name)} WHERE #{field.to_sql(operator, &block)} #{self.sql_operator(operator, field)} ? )"
        end

      else
        value = value.to_i if field_def.offset
        yield(:parameter, value)
        return "#{field.to_sql(operator, &block)} #{self.sql_operator(operator, field)} ?"
      end
    end

    def find_has_many_through_association(field, through)
      middle_table_association = nil
      field.klass.reflect_on_all_associations(:has_many).each do |reflection|
        class_name = reflection.options[:class_name].constantize.table_name if reflection.options[:class_name]
        middle_table_association = reflection.name if class_name == through.to_s
        middle_table_association = reflection.plural_name if reflection.plural_name == through.to_s
      end
      middle_table_association
    end

    def has_many_through_join(field_def)
      field = field_def.to_field(scoped_klass)
      many_class = scoped_klass
      through = definition.reflection_by_name(many_class, field_def.relation).options[:through]
      connection = many_class.connection

      # table names
      endpoint_table_name = field.klass.table_name
      many_table_name = many_class.table_name
      middle_table_name = definition.reflection_by_name(many_class, through).klass.table_name

      # primary and foreign keys + optional condition for the many to middle join
      pk1, fk1   = field.reflection_keys(definition.reflection_by_name(many_class, through))
      condition1 = field.reflection_conditions(definition.reflection_by_name(field.klass, middle_table_name))

      # primary and foreign keys + optional condition for the endpoint to middle join
      middle_table_association = find_has_many_through_association(field, through) || middle_table_name
      pk2, fk2   = field.reflection_keys(definition.reflection_by_name(field.klass, middle_table_association))
      condition2 = field.reflection_conditions(definition.reflection_by_name(many_class, field_def.relation))

      <<-SQL
        #{connection.quote_table_name(many_table_name)}
        INNER JOIN #{connection.quote_table_name(middle_table_name)}
        ON #{connection.quote_table_name(many_table_name)}.#{connection.quote_column_name(pk1)} = #{connection.quote_table_name(middle_table_name)}.#{connection.quote_column_name(fk1)} #{condition1}
        INNER JOIN #{connection.quote_table_name(endpoint_table_name)}
        ON #{connection.quote_table_name(middle_table_name)}.#{connection.quote_column_name(fk2)} = #{connection.quote_table_name(endpoint_table_name)}.#{connection.quote_column_name(pk2)} #{condition2}
      SQL
    end

    # This module gets included into the Field class to add SQL generation.
    module Field

      # Return an SQL representation for this field. Also make sure that
      # the relation which includes the search field is included in the
      # SQL query.
      #
      # This function may yield an :include that should be used in the
      # ActiveRecord::Base#find call, to make sure that the field is available
      # for the SQL query.
      def to_sql(operator = nil, &block) # :yields: finder_option_type, value
        num = rand(1000000)
        connection = klass.connection
        if field_definition.key_relation
          yield(:joins, construct_join_sql(field_definition.key_relation, num) )
          yield(:keycondition, "#{key_klass.table_name}_#{num}.#{connection.quote_column_name(field_definition.key_field.to_s)} = ?")
          klass_table_name = field_definition.relation ? "#{klass.table_name}_#{num}" : klass.table_name
          return "#{connection.quote_table_name(klass_table_name)}.#{connection.quote_column_name(field_definition.field.to_s)}"
        elsif field_definition.key_field
          yield(:joins, construct_simple_join_sql(num))
          yield(:keycondition, "#{key_klass.table_name}_#{num}.#{connection.quote_column_name(field_definition.key_field.to_s)} = ?")
          klass_table_name = field_definition.relation ? "#{klass.table_name}_#{num}" : klass.table_name
          return "#{connection.quote_table_name(klass_table_name)}.#{connection.quote_column_name(field_definition.field.to_s)}"
        elsif field_definition.relation
          yield(:include, field_definition.relation)
        end
        column_name = connection.quote_table_name(klass.table_name.to_s) + "." + connection.quote_column_name(field_definition.field.to_s)
        column_name = "(#{column_name} >> #{field_definition.offset*field_definition.word_size} & #{2**field_definition.word_size - 1})" if field_definition.offset
        column_name
      end

      # This method construct join statement for a key value table
      # It assume the following table structure
      #  +----------+  +---------+ +--------+
      #  | main     |  | value   | | key    |
      #  | main_pk  |  | main_fk | |        |
      #  |          |  | key_fk  | | key_pk |
      #  +----------+  +---------+ +--------+
      # uniq name for the joins are needed in case that there is more than one condition
      # on different keys in the same query.
      def construct_join_sql(key_relation, num)
        join_sql = ""
        connection = klass.connection
        key = key_relation.to_s.singularize.to_sym

        key_table = definition.reflection_by_name(klass, key).table_name
        value_table = klass.table_name.to_s

        value_table_fk_key, key_table_pk = reflection_keys(definition.reflection_by_name(klass, key))

        main_reflection = definition.reflection_by_name(definition.klass, field_definition.relation)
        if main_reflection
          main_table = definition.klass.table_name
          main_table_pk, value_table_fk_main = reflection_keys(definition.reflection_by_name(definition.klass, field_definition.relation))

          join_sql = "\n  INNER JOIN #{connection.quote_table_name(value_table)} #{value_table}_#{num} ON (#{main_table}.#{main_table_pk} = #{value_table}_#{num}.#{value_table_fk_main})"
          value_table = " #{value_table}_#{num}"
        end
        join_sql += "\n INNER JOIN #{connection.quote_table_name(key_table)} #{key_table}_#{num} ON (#{key_table}_#{num}.#{key_table_pk} = #{value_table}.#{value_table_fk_key}) "

        return join_sql
      end

      # This method construct join statement for a key value table
      # It assume the following table structure
      #  +----------+  +---------+
      #  | main     |  | key     |
      #  | main_pk  |  | value   |
      #  |          |  | main_fk |
      #  +----------+  +---------+
      # uniq name for the joins are needed in case that there is more than one condition
      # on different keys in the same query.
      def construct_simple_join_sql(num)
        connection = klass.connection
        key_value_table = klass.table_name

        main_table = definition.klass.table_name
        main_table_pk, value_table_fk_main = reflection_keys(definition.reflection_by_name(definition.klass, field_definition.relation))

        join_sql = "\n  INNER JOIN #{connection.quote_table_name(key_value_table)} #{key_value_table}_#{num} ON (#{connection.quote_table_name(main_table)}.#{connection.quote_column_name(main_table_pk)} = #{key_value_table}_#{num}.#{connection.quote_column_name(value_table_fk_main)})"
        return join_sql
      end

      def reflection_keys(reflection)
        pk = reflection.klass.primary_key
        fk = reflection.options[:foreign_key]
        # activerecord prior to 3.1 doesn't respond to foreign_key method and hold the key name in the reflection primary key
        fk ||= reflection.respond_to?(:foreign_key) ? reflection.foreign_key : reflection.primary_key_name
        reflection.macro == :belongs_to ? [fk, pk] : [pk, fk]
      end

      def reflection_conditions(reflection)
        return unless reflection
        conditions = reflection.options[:conditions]
        conditions ||= "#{reflection.options[:source]}_type = '#{reflection.options[:source_type]}'" if reflection.options[:source] && reflection.options[:source_type]
        conditions ||= "#{reflection.try(:foreign_type)} = '#{reflection.klass}'" if  reflection.options[:polymorphic]
        " AND #{conditions}" if conditions
      end

      def to_ext_method_sql(key, operator, value, &block)
        raise ScopedSearch::QueryNotSupported, "'#{definition.klass}' doesn't respond to '#{ext_method}'" unless definition.klass.respond_to?(ext_method)
        conditions = definition.klass.send(ext_method.to_sym,key, operator, value) rescue {}
        raise ScopedSearch::QueryNotSupported, "external method '#{ext_method}' should return hash" unless conditions.kind_of?(Hash)
        sql = ''
        conditions.map do |notification, content|
          case notification
            when :include then yield(:include, content)
            when :joins then yield(:joins, content)
            when :conditions then sql = content
            when :parameter then content.map{|c| yield(:parameter, c)}
          end
        end
        return sql
      end
    end

    # This module contains modules for every AST::Node class to add SQL generation.
    module AST

      # Defines the to_sql method for AST LeadNodes
      module LeafNode
        def to_sql(builder, definition, &block)
          # for boolean fields allow a short format (example: for 'enabled = true' also allow 'enabled')
          field_def = definition.field_by_name(value)
          if field_def && field_def.set? && field_def.complete_value.values.include?(true)
            key = field_def.complete_value.map{|k,v| k if v == true}.compact.first
            return builder.set_test(field_def, :eq, key, &block)
          end
          # Search keywords found without context, just search on all the default fields
          fragments = definition.default_fields_for(builder.scoped_klass, value).map do |field_def|
            builder.sql_test(field_def, field_def.to_field(builder.scoped_klass).default_operator, value,'', &block)
          end

          case fragments.length
            when 0 then nil
            when 1 then fragments.first
            else "#{fragments.join(' OR ')}"
          end
        end
      end

      # Defines the to_sql method for AST operator nodes
      module OperatorNode

        # Returns an IS (NOT) NULL SQL fragment
        def to_null_sql(builder, definition, &block)
          field_def = definition.field_by_name(rhs.value)
          raise ScopedSearch::QueryNotSupported, "Field '#{rhs.value}' not recognized for searching!" unless field_def

          if field_def.key_field
            yield(:parameter, rhs.value.to_s.sub(/^.*\./,''))
          end
          case operator
            when :null    then "#{field_def.to_field(builder.scoped_klass).to_sql(builder, &block)} IS NULL"
            when :notnull then "#{field_def.to_field(builder.scoped_klass).to_sql(builder, &block)} IS NOT NULL"
          end
        end

        # No explicit field name given, run the operator on all default fields
        def to_default_fields_sql(builder, definition, &block)
          raise ScopedSearch::QueryNotSupported, "Value not a leaf node" unless rhs.kind_of?(ScopedSearch::QueryLanguage::AST::LeafNode)

          # Search keywords found without context, just search on all the default fields
          fragments = definition.default_fields_for(builder.scoped_klass, rhs.value, operator).map { |field_def|
                          builder.sql_test(field_def, operator, rhs.value,'', &block) }.compact

          case fragments.length
            when 0 then nil
            when 1 then fragments.first
            else "#{fragments.join(' OR ')}"
          end
        end

        # Explicit field name given, run the operator on the specified field only
        def to_single_field_sql(builder, definition, &block)
          raise ScopedSearch::QueryNotSupported, "Field name not a leaf node" unless lhs.kind_of?(ScopedSearch::QueryLanguage::AST::LeafNode)
          raise ScopedSearch::QueryNotSupported, "Value not a leaf node"      unless rhs.kind_of?(ScopedSearch::QueryLanguage::AST::LeafNode)

          # Search only on the given field.
          field_def = definition.field_by_name(lhs.value)
          raise ScopedSearch::QueryNotSupported, "Field '#{lhs.value}' not recognized for searching!" unless field_def

          # see if the value passes user defined validation
          validate_value(field_def, rhs.value)

          builder.sql_test(field_def, operator, rhs.value,lhs.value, &block)
        end

        # Convert this AST node to an SQL fragment.
        def to_sql(builder, definition, &block)
          if operator == :not && children.length == 1
            builder.to_not_sql(rhs, definition, &block)
          elsif [:null, :notnull].include?(operator)
            to_null_sql(builder, definition, &block)
          elsif children.length == 1
            to_default_fields_sql(builder, definition, &block)
          elsif children.length == 2
            to_single_field_sql(builder, definition, &block)
          else
            raise ScopedSearch::QueryNotSupported, "Don't know how to handle this operator node: #{operator.inspect} with #{children.inspect}!"
          end
        end

        private

        def validate_value(field_def, value)
          validator = field_def.validator
          if validator
            valid = validator.call(value)
            raise ScopedSearch::QueryNotSupported, "Value '#{value}' is not valid for field '#{field_def.field}'" unless valid
          end
        end
      end

      # Defines the to_sql method for AST AND/OR operators
      module LogicalOperatorNode
        def to_sql(builder, definition, &block)
          fragments = children.map { |c| c.to_sql(builder, definition, &block) }.map { |sql| "(#{sql})" unless sql.blank? }.compact
          fragments.empty? ? nil : "#{fragments.join(" #{operator.to_s.upcase} ")}"
        end
      end
    end

    # The PostgreSQLAdapter make sure that searches are case sensitive when
    # using the like/unlike operators, by using the PostrgeSQL-specific
    # <tt>ILIKE operator</tt> instead of <tt>LIKE</tt>.
    class PostgreSQLAdapter < ScopedSearch::QueryBuilder

      # Switches out the default query generation of the <tt>sql_test</tt>
      # method if full text searching is enabled and a text search is being
      # performed.
      def sql_test(field_def, operator, value, lhs, &block)
        if [:like, :unlike].include?(operator) && field_def.full_text_search
          yield(:parameter, value)
          negation = (operator == :unlike) ? "NOT " : ""
          locale = (field_def.full_text_search == true) ? 'english' : field_def.full_text_search
          return "#{negation}to_tsvector('#{locale}', #{field_def.to_field(scoped_klass).to_sql(operator, &block)}) #{self.sql_operator(operator, field_def.to_field(scoped_klass))} to_tsquery('#{locale}', ?)"
        else
          super
        end
      end

      # Switches out the default LIKE operator in the default <tt>sql_operator</tt>
      # method for ILIKE or @@ if full text searching is enabled.
      def sql_operator(operator, field)
        raise ScopedSearch::QueryNotSupported, "the operator '#{operator}' is not supported for field type '#{field.type}'" if [:like, :unlike].include?(operator) and !field.textual?
        return '@@' if [:like, :unlike].include?(operator) && field.field_definition.full_text_search
        case operator
          when :like   then 'ILIKE'
          when :unlike then 'NOT ILIKE'
          else super(operator, field)
        end
      end

      # Returns a NOT (...)  SQL fragment that negates the current AST node's children
      def to_not_sql(rhs, definition, &block)
        "NOT COALESCE(#{rhs.to_sql(self, definition, &block)}, false)"
      end

      def order_by(order, &block)
        sql = super(order, &block)
        if sql
          field_def, _ = find_field_def_for_order_by(order, &block)
          sql += sql.include?('DESC') ? ' NULLS LAST ' : ' NULLS FIRST ' if !field_def.nil? && field_def.to_field(scoped_klass).column.null
        end
        sql
      end
    end
  end

  # Include the modules into the corresponding classes
  # to add SQL generation capabilities to them.

  Definition::Field.send(:include, QueryBuilder::Field)
  QueryLanguage::AST::LeafNode.send(:include, QueryBuilder::AST::LeafNode)
  QueryLanguage::AST::OperatorNode.send(:include, QueryBuilder::AST::OperatorNode)
  QueryLanguage::AST::LogicalOperatorNode.send(:include, QueryBuilder::AST::LogicalOperatorNode)
end
