require 'active_support/core_ext/array/conversions'

module RubyBBCode
  # TagSifter is in charge of building up the BBTree with nodes as it parses through the
  # supplied text such as
  #    "[b]I'm bold and the next word is [i]ITALIC[/i][b]"
  class TagSifter
    attr_reader :bbtree, :errors

    def initialize(text_to_parse, dictionary, escape_html = true)
      @text = escape_html ? text_to_parse.gsub('<', '&lt;').gsub('>', '&gt;').gsub('"', '&quot;') : text_to_parse

      @dictionary = dictionary # dictionary containing all allowed/defined tags
      @bbtree = BBTree.new(nodes: TagCollection.new)
      @ti = nil
      @errors = []
    end

    def valid?
      @errors.empty?
    end

    # BBTree#process_text is responsible for parsing the actual BBCode text and converting it
    # into a 'syntax tree' of nodes, each node represeting either a tag type or content for a tag
    # once this tree is built, the to_html method can be invoked where the tree is finally
    # converted into HTML syntax.
    def process_text
      regex_string = '((\[ (\/)? ( \* | (\w+)) ((=[^\[\]]+) | (\s\w+=\w+)* | ([^\]]*))? \]) | ([^\[]+))'
      @text.scan(/#{regex_string}/ix) do |tag_info|
        @ti = TagInfo.new(tag_info, @dictionary)

        validate_element

        case @ti.type
        when :opening_tag
          element = { is_tag: true, tag: @ti[:tag], definition: @ti.definition, errors: @ti[:errors], nodes: TagCollection.new }
          element[:invalid_quick_param] = true if @ti.invalid_quick_param?
          element[:params] = get_formatted_element_params

          @bbtree.retrogress_bbtree if self_closing_tag_reached_a_closer?

          @bbtree.build_up_new_tag(element)

          @bbtree.escalate_bbtree(element)
        when :text
          tag_def = @bbtree.current_node.definition
          if tag_def && (tag_def[:multi_tag] == true)
            set_multi_tag_to_actual_tag
            tag_def = @bbtree.current_node.definition
          end

          if within_open_tag? && tag_def[:require_between]
            between = get_formatted_between
            @bbtree.current_node[:between] = between
            if use_text_as_parameter?
              value_array = tag_def[:quick_param_format].nil? ? true : between.scan(tag_def[:quick_param_format])[0]
              if value_array.nil?
                if @ti[:invalid_quick_param].nil?
                  # Add text element (with error(s))
                  add_element = true

                  # ...and clear between, as this would result in two 'between' texts
                  @bbtree.current_node[:between] = ''
                end
              else
                # Between text can be used as (first) parameter
                @bbtree.current_node[:params][tag_def[:param_tokens][0][:token]] = between
              end
            end
            # Don't add this text node, as it is used as between (and might be used as first param)
            next unless add_element
          end

          create_text_element
        when :closing_tag
          if @ti[:wrong_closing]
            # Convert into text, so it
            @ti.handle_tag_as_text
            create_text_element
          else
            @bbtree.retrogress_bbtree if parent_of_self_closing_tag? && within_open_tag?
            @bbtree.retrogress_bbtree
          end
        end
      end

      validate_all_tags_closed_off
      validate_stack_level_too_deep_potential
    end

    private

    def set_multi_tag_to_actual_tag
      # Try to find the actual tag
      tag = get_actual_tag
      if tag == :tag_not_found
        # Add error
        add_tag_error "Unknown multi-tag type for [#{@bbtree.current_node[:tag]}]", @bbtree.current_node
      else
        # Update current_node with found information, so it behaves as the actual tag
        @bbtree.current_node[:definition] = @dictionary[tag]
        @bbtree.current_node[:tag] = tag
      end
    end

    # The media tag support multiple other tags, this method checks the tag url param to find actual tag type (to use)
    def get_actual_tag
      supported_tags = @bbtree.current_node[:definition][:supported_tags]

      supported_tags.each do |tag|
        regex_list = @dictionary[tag][:url_matches]

        regex_list.each do |regex|
          return tag if regex =~ @ti.text
        end
      end
      :tag_not_found
    end

    def create_text_element
      element = { is_tag: false, text: @ti.text, errors: @ti[:errors] }
      @bbtree.build_up_new_tag(element)
    end

    # Gets the params, and format them if needed...
    def get_formatted_element_params
      params = @ti[:params]
      if @ti.definition[:url_matches]
        # perform special formatting for certain tags
        params[:url] = match_url_id(params[:url], @ti.definition[:url_matches])
      end
      params
    end

    # Get 'between tag' for tag
    def get_formatted_between
      between = @ti[:text]
      # perform special formatting for certain tags
      between = match_url_id(between, @bbtree.current_node.definition[:url_matches]) if @bbtree.current_node.definition[:url_matches]
      between
    end

    def match_url_id(url, regex_matches)
      regex_matches.each do |regex|
        if url =~ regex
          id = Regexp.last_match(1)
          return id
        end
      end

      url # if we couldn't find a match, then just return the url, hopefully it's a valid ID...
    end

    # Validates the element
    def validate_element
      return unless valid_text_or_opening_element?
      return unless valid_closing_element?
      return unless valid_param_supplied_as_text?
    end

    def valid_text_or_opening_element?
      if @ti.element_is_text? || @ti.element_is_opening_tag?
        return false unless valid_opening_tag?
        return false unless valid_constraints_on_child?
      end
      true
    end

    def valid_opening_tag?
      if @ti.element_is_opening_tag?
        if @ti.only_allowed_in_parent_tags? && (!within_open_tag? || !@ti.allowed_in?(parent_tag[:tag])) && !self_closing_tag_reached_a_closer?
          # Tag doesn't belong in the last opened tag
          throw_child_requires_specific_parent_error
          return false
        end

        if @ti.invalid_quick_param?
          throw_invalid_quick_param_error @ti
          return false
        end

        # Note that if allow_between_as_param is true, other checks already test the (correctness of the) 'between parameter'
        unless @ti.definition[:param_tokens].nil? || (@ti.definition[:allow_between_as_param] == true)
          # Check if all required parameters are added
          @ti.definition[:param_tokens].each do |token|
            add_tag_error "Tag [#{@ti[:tag]}] must have '#{token[:token]}' parameter" if @ti[:params][token[:token]].nil? && token[:optional].nil?
          end

          # Check if no 'custom parameters' are added
          @ti[:params].keys.each do |token|
            add_tag_error "Tag [#{@ti[:tag]}] doesn't have a '#{token}' parameter" if @ti.definition[:param_tokens].find { |param_token| param_token[:token] == token }.nil?
          end
        end
      end
      true
    end

    def self_closing_tag_reached_a_closer?
      @ti.definition[:self_closable] && (@bbtree.current_node[:tag] == @ti[:tag])
    end

    def valid_constraints_on_child?
      if within_open_tag? && parent_has_constraints_on_children?
        # Check if the found tag is allowed
        last_tag_def = parent_tag[:definition]
        allowed_tags = last_tag_def[:only_allow]
        if (!@ti[:is_tag] && (last_tag_def[:require_between] != true) && (@ti[:text].lstrip != '')) || (@ti[:is_tag] && (allowed_tags.include?(@ti[:tag]) == false)) # TODO: refactor this, it's just too long
          # Last opened tag does not allow tag
          throw_parent_prohibits_this_child_error
          return false
        end
      end
      true
    end

    def valid_closing_element?
      if @ti.element_is_closing_tag?

        if parent_tag.nil?
          add_tag_error "Closing tag [/#{@ti[:tag]}] doesn't match an opening tag"
          @ti[:wrong_closing] = true
          return false
        end

        if (parent_tag[:tag] != @ti[:tag]) && !parent_of_self_closing_tag?
          # Make an exception for 'supported tags'
          if @ti.definition[:supported_tags].nil? || !@ti.definition[:supported_tags].include?(parent_tag[:tag])
            add_tag_error "Closing tag [/#{@ti[:tag]}] doesn't match [#{parent_tag[:tag]}]"
            @ti[:wrong_closing] = true
            return false
          end
        end

        tag_def = @bbtree.current_node.definition
        if tag_def[:require_between] && @bbtree.current_node[:between].nil? && @bbtree.current_node[:nodes].empty?
          err = "No text between [#{@ti[:tag]}] and [/#{@ti[:tag]}] tags."
          err = "Cannot determine multi-tag type: #{err}" if tag_def[:multi_tag]
          add_tag_error err, @bbtree.current_node
          return false
        end
      end
      true
    end

    def parent_of_self_closing_tag?
      was_last_tag_self_closable = @bbtree.current_node[:definition][:self_closable] unless @bbtree.current_node[:definition].nil?

      was_last_tag_self_closable && last_tag_fit_in_this_tag?
    end

    def last_tag_fit_in_this_tag?
      @ti.definition[:only_allow]&.each do |tag|
        return true if tag == @bbtree.current_node[:tag]
      end
      false
    end
    # This validation is for text elements with between text
    # that might be construed as a param.
    # The validation code checks if the params match constraints
    # imposed by the node/tag/parent.
    def valid_param_supplied_as_text?
      tag_def = @bbtree.current_node.definition

      if within_open_tag? && use_text_as_parameter? && @ti[:is_tag] && has_no_text_node?
        add_tag_error 'between parameter must be plain text'
        return false
      end

      # this conditional ensures whether the validation is apropriate to this tag type
      if @ti.element_is_text? && within_open_tag? && tag_def[:require_between] && use_text_as_parameter? && !tag_def[:quick_param_format].nil?

        # check if valid
        if @ti[:text].match(tag_def[:quick_param_format]).nil?
          add_tag_error tag_def[:quick_param_format_description].gsub('%param%', @ti[:text])
          return false
        end
      end
      true
    end

    def validate_all_tags_closed_off
      return unless expecting_a_closing_tag?

      # if we're still expecting a closing tag and we've come to the end of the string... throw error(s)
      @bbtree.tags_list.each do |tag|
        add_tag_error "[#{tag[:tag]}] not closed", tag
        tag[:closed] = false
      end
    end

    def validate_stack_level_too_deep_potential
      throw_stack_level_will_be_too_deep_error if @bbtree.nodes.count > 2200
    end

    def throw_child_requires_specific_parent_error
      err = "[#{@ti[:tag]}] can only be used in [#{@ti.definition[:only_in].to_sentence(to_sentence_bbcode_tags)}]"
      err += ", so using it in a [#{parent_tag[:tag]}] tag is not allowed" if expecting_a_closing_tag?
      add_tag_error err
    end

    def throw_invalid_quick_param_error(tag)
      add_tag_error tag.definition[:quick_param_format_description].gsub('%param%', tag[:invalid_quick_param]), tag
    end

    def throw_parent_prohibits_this_child_error
      allowed_tags = parent_tag[:definition][:only_allow]
      err = "[#{parent_tag[:tag]}] can only contain [#{allowed_tags.to_sentence(to_sentence_bbcode_tags)}] tags, so "
      err += "[#{@ti[:tag]}]" if @ti[:is_tag]
      err += "\"#{@ti[:text]}\"" unless @ti[:is_tag]
      err += ' is not allowed'
      add_tag_error err
    end

    def throw_stack_level_will_be_too_deep_error
      @errors << 'Stack level would go too deep.  You must be trying to process a text containing thousands of BBTree nodes at once.  (limit around 2300 tags containing 2,300 strings).  Check RubyBBCode::TagCollection#to_html to see why this validation is needed.'
    end

    def to_sentence_bbcode_tags
      { words_connector: '], [',
        two_words_connector: '] and [',
        last_word_connector: '] and [' }
    end

    def has_no_text_node?
      @bbtree.current_node[:nodes].blank? || @bbtree.current_node[:nodes][0][:text].nil?
    end

    def expecting_a_closing_tag?
      @bbtree.expecting_a_closing_tag?
    end

    def within_open_tag?
      @bbtree.within_open_tag?
    end

    def use_text_as_parameter?
      tag = @bbtree.current_node
      tag.definition[:allow_between_as_param] && tag.params_not_set? && !tag.invalid_quick_param?
    end

    def parent_tag
      @bbtree.parent_tag
    end

    def parent_has_constraints_on_children?
      @bbtree.parent_has_constraints_on_children?
    end

    private

    def add_tag_error(message, tag = @ti)
      @errors << message
      tag[:errors] << message
    end
  end
end
