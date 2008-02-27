# $Id$

# Equivalent to a header guard in C/C++
# Used to prevent the spec helper from being loaded more than once
unless defined? ::Webby::Renderer

require 'erb'

module Webby

# The Webby::Renderer is used to _filter_ and _layout_ the text found in the
# resource page files in the content directory.
#
# A page is filtered based on the settings of the 'filter' option in the
# page's meta-data information. For example, if 'textile' is specified as
# a filter, then the page will be run through the RedCloth markup filter.
# More than one filter can be used on a page; they will be run in the
# order specified in the meta-data.
#
# A page is rendered into a layout specified by the 'layout' option in the
# page's meta-data information.
#
class Renderer
  include ERB::Util

  # :stopdoc:
  class Error < StandardError; end
  @@stack = []
  # :startdoc:

  # call-seq:
  #    Renderer.write( page )
  #
  # Render the given _page_ and write the resulting output to the page's
  # destination. If the _page_ uses pagination, then multiple destination
  # files will be created -- one for each paginated data set in the page.
  #
  def self.write( page )
    renderer = self.new(page)

    loop {
      ::File.open(page.destination, 'w') do |fd|
        fd.write renderer.layout_page
      end
      break unless renderer.__send__(:_next_page)
    }
  end

  # call-seq:
  #    Renderer.new( page )
  #
  # Create a new renderer for the given _page_. The renderer will apply the
  # desired filters to the _page_ (from the page's meta-data) and then
  # render the filtered page into the desired layout.
  #
  def initialize( page )
    unless page.instance_of? Resources::Page
      raise ArgumentError,
            "only page resources can be rendered '#{page.path}'"
    end

    @page = page
    @pages = Resources.pages
    @partials = Resources.partials
    @content = nil
    @config = ::Webby.site

    @log = Logging::Logger[self]
  end

  # call-seq:
  #    layout_page    => string
  #
  # Apply the desired filters to the page and then render the filtered page
  # into the desired layout. The filters to apply to the page are determined
  # from the page's meta-data. The layout to use is also determined from the
  # page's meta-data.
  #
  def layout_page
    layouts = Resources.layouts
    obj = @page
    str = @page.render(self)

    @@stack << @page.path
    loop do
      lyt = layouts.find :filename => obj.layout
      break if lyt.nil?

      @content, str = str, ::Webby::Resources::File.read(lyt.path)
      str = _track_rendering(lyt.path) {
        Filters.process(self, lyt, str)
      }
      @content, obj = nil, lyt
    end

    @@stack.pop if @page.path == @@stack.last
    raise Error, "rendering stack corrupted" unless @@stack.empty?

    str
  rescue => err
    @log.error "while rendering page '#{@page.path}'"
    @log.error err
  end

  # call-seq:
  #    render_page    => string
  #
  # Apply the desired filters to the page. The filters to apply are
  # determined from the page's meta-data.
  #
  def render_page
    _track_rendering(@page.path) {
      Filters.process(self, @page, ::Webby::Resources::File.read(@page.path))
    }
  end

  # call-seq:
  #    render_partial( partial )    => string
  #
  # Render the given _partial_ into the current page. The _partial_ can
  # either be the name of the partial to render or a Partial object.
  #
  # In the former case, the partial is found by first looking in the
  # directory of the current for a partial of the same name. Failing that,
  # the search is expanded to include all directories in the site. The first
  # partial with a matching name is returned.
  #
  # In the latter case, Partial objects can be found by using the +find+
  # method of the <tt>@partials</tt> database hash. Please refer to
  # Webby::Resources::DB#find method for more information.
  #
  def render_partial( part, opts = {} )
    part = case part
      when String
        fn = '_' + part
        p = Resources.partials.find(
            :filename => fn, :in_directory => @page.dir ) rescue nil
        p ||= Resources.partials.find(:filename => fn)
        raise Error, "could not find partial '#{part}'" if p.nil?
        p
      when ::Webby::Resources::Partial
        part
      else raise Error, "expecting a partial or a partial name" end

    _track_rendering(part.path) {
      Filters.process(self, part, ::Webby::Resources::File.read(part.path))
    }
  end

  # call-seq:
  #    paginate( items, per_page ) {|item| block}
  #
  # Iterate the given _block_ for each item selected from the _items_ array
  # using the given number of items _per_page_. The first time the page is
  # rendered, the items passed to the block are selected using the range
  # (0...per_page). The next rendering selects (per_page...2*per_page). This
  # continues until all _items_ have been paginated.
  #
  # Calling this method creates a <code>@pager</code> object that can be
  # accessed from the page. The <code>@pager</code> contains information
  # about the next page, the current page number, the previous page, and the
  # number of items in the current page.
  #
  def paginate( items, count, &block )
    @pager ||= Paginator.new(items.length, count, @page) do |offset, per_page|
      items[offset,per_page]
    end.first

    @pager.each(&block)
  end

  # call-seq:
  #    get_binding    => binding
  #
  # Returns the current binding for the renderer.
  #
  def get_binding
    binding
  end


  private

  # call-seq:
  #    _next_page    => true or false
  #
  # Returns +true+ if there is a next page to render. Returns +false+ if
  # there is no next page or if pagination has not been configured for the
  # current page.
  #
  def _next_page
    return false unless defined? @pager and @pager

    # go to the next page; break out if there is no next page
    if @pager.next?
      @pager = @pager.next
    else
      @page.number = nil
      return false
    end

    true
  end

  # call-seq:
  #    _track_rendering( path ) {block}
  #
  # Keep track of the page rendering for the given _path_. The _block_ is
  # where the the page will be rendered.
  #
  # This method keeps a stack of the current pages being rendeered. It looks
  # for duplicates in the stack -- an indication of a rendering loop. When a
  # rendering loop is detected, an error is raised.
  #
  # This method returns whatever is returned from the _block_.
  #
  def _track_rendering( path )
    loop_error = @@stack.include? path
    @@stack << path

    if loop_error
      msg = "rendering loop detected for '#{path}'\n"
      msg << "    current rendering stack\n\t"
      msg << @@stack.join("\n\t")
      raise Error, msg
    end

    yield
  ensure
    @@stack.pop if path == @@stack.last
  end

end  # class Renderer
end  # module Webby

Webby.require_all_libs_relative_to(__FILE__, 'stelan')

end  # unless defined?

# EOF
