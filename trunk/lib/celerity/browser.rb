module Celerity
  class Browser
    include Container
    attr_accessor :page, :object
    attr_reader :webclient, :viewer
    
    def self.start(uri)
      browser = new
      browser.goto(uri)
      browser
    end
    
    # Creates a browser object. 
    #
    # ==== Options (opts)
    # :browser<:firefox, :ie>
    #   Set the BrowserVersion used by HtmlUnit. This changes the behaviour of Browser#text (amongst others..)
    #   Defaults to :ie.
    # :css<true, false, nil>::
    #   Enable CSS. Disabled by default.
    # :secure_ssl<true, false, nil>::
    #   Disable secure SSL. Enabled by default.
    # :resynchronize<true, false, nil>::
    #   Use HtmlUnit::NicelyResynchronizingAjaxController to resynchronize Ajax calls.
    #   (...but this seems to work anyway?!)
    # :javascript_exceptions<true, false, nil>::
    #   Throw exceptions on script errors. Disabled by default.
    # :status_code_exceptions<true, false, nil>::
    #   Throw exceptions on failing status codes (404++). Disabled by default.
    # ==== Returns
    # An instance of Celerity::Browser
    #
    #-- 
    # @public
    def initialize(opts = {})
      @opts = opts

      self.log_level = :warning
      # browser = RUBY_PLATFORM =~ /java/ ? ::HtmlUnit::BrowserVersion::FIREFOX_2 : ::HtmlUnit::BrowserVersion.FIREFOX_2
      browser = @opts[:browser] == :firefox ? ::HtmlUnit::BrowserVersion::FIREFOX_2 : ::HtmlUnit::BrowserVersion::INTERNET_EXPLORER_7_0
      @webclient = ::HtmlUnit::WebClient.new(browser)
      @webclient.throwExceptionOnScriptError = false unless opts[:javascript_exceptions]
      @webclient.throwExceptionOnFailingStatusCode = false unless opts[:status_code_exceptions]
      @webclient.cssEnabled = false unless opts[:css]
      @webclient.useInsecureSSL = true if opts[:secure_ssl] 
      @webclient.setAjaxController(::HtmlUnit::NicelyResynchronizingAjaxController.new) if opts[:resynchronize]

      @last_url, @page = nil
      @page_container  = self
      @error_checkers  = []
      find_viewer 
    end
    
    def method_missing(meth, *args)
      if type = meth.to_s[/^show_(.*)$/, 1]
        begin
          puts collection_string(type)
        rescue NoMethodError
          super
        end
      else
        super
      end
    end

    def goto(uri)
      uri = "http://#{uri}" unless uri =~ %r{://}
      self.page = @webclient.getPage(uri)
      uri
    end
    
    def close
      @page = nil
    end

    def url
      assert_exists
      @page.getWebResponse.getUrl.toString
    end
    
    def title
      @page ? @page.getTitleText : ''
    end

    def html
      @page ? @page.getWebResponse.getContentAsString : ''
    end

    def text
      return '' unless @page

      if @page.respond_to?("getContent")
        @page.getContent  
      else
        # # this has no whitespace
        # @page.documentElement.asText
        
        if @opts[:browser] == :firefox
          # # this is what firewatir does - only works with HtmlUnit::BrowserVersion::FIREFOX_2
          res = execute_script("document.body.textContent").getJavaScriptResult 
        else
          # this only works with HtmlUnit::BrowserVersion::INTERNET_EXPLORER_*, and isn't identical to Watir's ole_object.innerText
          res = execute_script("document.body.innerText").getJavaScriptResult 
        end
      end
    end

    def contains_text(expected_text)
      return nil unless exist?
      case expected_text
      when Regexp
        text().match(expected_text)
      when String
        text().index(expected_text)
      else
        raise ArgumentError, "Argument must be String or Regexp, but was #{expected_text.inspect}:#{expected_text.class}"
      end
    end

    def document
      @object
    end
    
    def back
      # TODO: this is naive, need capability from HtmlUnit  
      goto(@last_url) if @last_url
    end
    
    def refresh
      assert_exists
      self.page = @page.refresh
    end

    def execute_script(source)
      assert_exists
      @page.executeJavaScript(source.to_s)
    end

    def add_checker(checker = nil, &block)
      if block_given?
        @error_checkers << block
      elsif Proc === checker
        @error_checkers << checker
      else
        raise ArgumentError, "argument must be a Proc or block"
      end
    end
    
    def disable_checker(checker)
      @error_checkers.delete(checker)
    end

    # Set Java log level (default is :warning)
    # :finest, :finer, :fine, :config, :info, :warning or :severe
    def log_level=(level)
      java.util.logging.Logger.getLogger('com.gargoylesoftware.htmlunit').level = java.util.logging.Level.const_get(level.to_s.upcase)
    end
    
    def log_level
      java.util.logging.Logger.getLogger('com.gargoylesoftware.htmlunit').level.to_s.downcase.to_sym
    end

    def exist?
      !!@page
    end
    alias_method :exists?, :exist?

    # Allows you to temporarily switch to HtmlUnit's NicelyResynchronizingAjaxController to resynchronize ajax calls.
    # Example:
    #   @browser.resynchroniced do |b|
    #     b.link(:id, 'load_fancy_ajax_stuff').click
    #   end
    def resynchronized(&block)
      old_controller = @webclient.ajaxController
      @webclient.setAjaxController(::HtmlUnit::NicelyResynchronizingAjaxController.new)
      yield self
      @webclient.setAjaxController(old_controller)
    end

    # TODO: could be private?
    # check that we have a @page object
    # need to find a better way to handle this 
    def assert_exists
      raise UnknownObjectException, "no page loaded" unless exist?
    end
    
    # TODO: could be private?
    def run_error_checks
      @error_checkers.each { |e| e.call(self) }
    end
    
    def page=(value)
      @last_url = url() if exist?
      @page = value
      if @page.respond_to?("getDocumentElement")
        @object = @page.getDocumentElement
      end
      render if @viewer
      run_error_checks
      
      value
    end
    
    private
    
    def collection_string(collection_method)
      collection = self.send collection_method
      result = "Found #{collection.size} #{collection_method.downcase}\n"
      collection.each_with_index do |element, index|
        result << "#{index+1}: #{element.attribute_string}\n"
      end
      return result
    end
    
    def render
      @viewer.render_html(html, url) 
    rescue DRb::DRbConnError, Errno::ECONNREFUSED => e
      @viewer = nil
    end    
    
    def find_viewer
      # FIXME: not ideal
      require 'drb'
      viewer = DRbObject.new_with_uri("druby://127.0.0.1:6429")
      @viewer = viewer if viewer.respond_to?(:render_html)
    rescue DRb::DRbConnError, Errno::ECONNREFUSED
      @viewer = nil
    end
    
  end # Browser
end # Celerity