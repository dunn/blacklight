module Blacklight
  class DocumentPresenter
    include ActionView::Helpers::OutputSafetyHelper
    include ActionView::Helpers::TagHelper
    extend Deprecation

    # @param [SolrDocument] document
    # @param [ActionController::Base] controller scope for linking and generating urls
    # @param [Blacklight::Configuration] configuration
    def initialize(document, controller, configuration = controller.blacklight_config)
      @document = document
      @configuration = configuration
      @controller = controller
    end

    ##
    # Get the value of the document's "title" field, or a placeholder
    # value (if empty)
    #
    # @param [SolrDocument] document
    # @return [String]
    def document_heading
      fields = Array(@configuration.view_config(:show).title_field)
      f = fields.find { |field| @document.has? field }

      if f.nil?
        render_field_value(@document.id)
      else
        render_field_value(@document[f])
      end
    end

    ##
    # Create <link rel="alternate"> links from a documents dynamically
    # provided export formats. Returns empty string if no links available.
    #
    # @params [SolrDocument] document
    # @params [Hash] options
    # @option options [Boolean] :unique ensures only one link is output for every
    #     content type, e.g. as required by atom
    # @option options [Array<String>] :exclude array of format shortnames to not include in the output
    def link_rel_alternates(options = {})
      options = { unique: false, exclude: [] }.merge(options)

      seen = Set.new

      safe_join(@document.export_formats.map do |format, spec|
        next if options[:exclude].include?(format) || (options[:unique] && seen.include?(spec[:content_type]))

        seen.add(spec[:content_type])

        tag(:link, rel: "alternate", title: format, type: spec[:content_type], href: @controller.polymorphic_url(@document, format: format))
      end.compact, "\n")
    end

    ##
    # Get the document's "title" to display in the <title> element.
    # (by default, use the #document_heading)
    #
    # @see #document_heading
    # @return [String]
    def document_show_html_title
      if @configuration.view_config(:show).html_title_field
        fields = Array(@configuration.view_config(:show).html_title_field)
        f = fields.find { |field| @document.has? field }

        if f.nil?
          render_field_value(@document.id)
        else
          render_field_value(@document[f])
        end
      else
        document_heading
      end
    end

    ##
    # Render a value (or array of values) from a field
    #
    # @param [String] value or list of values to display
    # @param [Blacklight::Solr::Configuration::Field] solr field configuration
    # @return [String]
    def render_field_value value=nil, field_config=nil
      safe_values = Array(value).collect { |x| x.respond_to?(:force_encoding) ? x.force_encoding("UTF-8") : x }

      if field_config and field_config.itemprop
        safe_values = safe_values.map { |x| content_tag :span, x, :itemprop => field_config.itemprop }
      end

      render_values(safe_values, field_config)
    end

    ##
    # Render a fields values as a string
    # @param [Array] values to display
    # @param [Blacklight::Solr::Configuration::Field] solr field configuration
    # @return [String]
    def render_values(values, field_config = nil)
      options = {}
      options = field_config.separator_options if field_config && field_config.separator_options

      values.map { |x| html_escape(x) }.to_sentence(options).html_safe
    end

    ##
    # Render the document index heading
    #
    # @param [Symbol, Proc, String] field Render the given field or evaluate the proc or render the given string
    # @param [Hash] opts
    def render_document_index_label(field, opts = {})
      label = case field
      when Symbol
        @document[field]
      when Proc
        field.call(@document, opts)
      when String
        field
      end
      render_field_value label || @document.id
    end

    ##
    # Render the index field label for a document
    #
    #   Allow an extention point where information in the document
    #   may drive the value of the field
    #   @param [String] field
    #   @param [Hash] opts
    #   @options opts [String] :value
    def render_index_field_value field, options = {}
      field_config = @configuration.index_fields[field]
      value = options[:value] || get_field_values(field, field_config, options)

      render_field_value value, field_config
    end

    ##
    # Render the show field value for a document
    #
    #   Allow an extention point where information in the document
    #   may drive the value of the field
    #   @param [String] field
    #   @param [Hash] options
    #   @options opts [String] :value
    def render_document_show_field_value field, options={}
      field_config = @configuration.show_fields[field]
      value = options[:value] || get_field_values(field, field_config, options)

      render_field_value value, field_config
    end

    ##
    # Get the value for a document's field, and prepare to render it.
    # - highlight_field
    # - accessor
    # - solr field
    #
    # Rendering:
    #   - helper_method
    #   - link_to_search
    # TODO : maybe this should be merged with render_field_value, and the ugly signature 
    # simplified by pushing some of this logic into the "model"
    # @param [SolrDocument] document
    # @param [String] field name
    # @param [Blacklight::Solr::Configuration::Field] solr field configuration
    # @param [Hash] options additional options to pass to the rendering helpers
    def get_field_values field, field_config, options = {}
      # retrieving values
      value = case    
        when (field_config and field_config.highlight)
          # retrieve the document value from the highlighting response
          @document.highlight_field(field_config.field).map(&:html_safe) if @document.has_highlight_field? field_config.field
        when (field_config and field_config.accessor)
          # implicit method call
          if field_config.accessor === true
            @document.send(field)
          # arity-1 method call (include the field name in the call)
          elsif !field_config.accessor.is_a?(Array) && @document.method(field_config.accessor).arity != 0
            @document.send(field_config.accessor, field)
          # chained method calls
          else
            Array(field_config.accessor).inject(@document) do |result, method|
              result.send(method)
            end
          end
        when field_config
          # regular document field
          if field_config.default and field_config.default.is_a? Proc
            @document.fetch(field_config.field, &field_config.default)
          else
            @document.fetch(field_config.field, field_config.default)
          end
        when field
          @document[field]
      end

      # rendering values
      case
        when (field_config and field_config.helper_method)
          @controller.send(field_config.helper_method, options.merge(document: @document, field: field, config: field_config, value: value))
        when (field_config and field_config.link_to_search)
          link_field = if field_config.link_to_search === true
            field_config.key
          else
            field_config.link_to_search
          end

          Array(value).map do |v|
            @controller.link_to render_field_value(v, field_config), @controller.search_action_path(@controller.search_state.reset.add_facet_params(link_field, v))
          end if field
        else
          value
        end
    end

    def html_escape(*args)
      ERB::Util.html_escape(*args)
    end
  end
end
