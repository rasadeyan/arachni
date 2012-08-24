=begin
    Copyright 2010-2012 Tasos Laskos <tasos.laskos@gmail.com>

    Licensed under the Apache License, Version 2.0 (the "License");
    you may not use this file except in compliance with the License.
    You may obtain a copy of the License at

        http://www.apache.org/licenses/LICENSE-2.0

    Unless required by applicable law or agreed to in writing, software
    distributed under the License is distributed on an "AS IS" BASIS,
    WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
    See the License for the specific language governing permissions and
    limitations under the License.
=end

require 'webrick'
require 'uri'

require Arachni::Options.dir['lib'] + 'element/base'

module Arachni::Element

COOKIE = 'cookie'

#
# Represents a Cookie object and provides helper class methods for parsing, encoding, etc.
#
# @author Tasos "Zapotek" Laskos <tasos.laskos@gmail.com>
#
class Cookie < Arachni::Element::Base

    #
    # Default cookie values
    #
    DEFAULT = {
           "name" => nil,
          "value" => nil,
        "version" => 0,
           "port" => nil,
        "discard" => nil,
    "comment_url" => nil,
        "expires" => nil,
        "max_age" => nil,
        "comment" => nil,
         "secure" => nil,
           "path" => nil,
         "domain" => nil,
       "httponly" => false
    }

    def initialize( url, raw = {} )
        super( url, raw )

        self.action = @url
        self.method = 'get'

        @raw ||= {}
        if @raw['name'] && @raw['value']
            self.auditable = { @raw['name'] => @raw['value'] }
        else
            self.auditable = raw.dup
        end

        @raw = @raw.merge( DEFAULT.merge( @raw ) )
        if @raw['value'] && !@raw['value'].empty?
            @raw['value'] = decode( @raw['value'].to_s )
        end

        parsed_uri = uri_parse( @url )
        if !@raw['path']
            path = parsed_uri.path
            path = !path.empty? ? path : '/'
            @raw['path'] = path
        end

        @raw['domain'] ||= parsed_uri.host

        @raw['max_age'] = @raw['max_age'] if @raw['max_age']

        @orig   = self.auditable.dup
        @orig.freeze
    end

    #
    # Overrides {Capabilities::Auditable#audit} to enforce cookie exclusion
    # settings from {Arachni::Options#exclude_cookies}.
    #
    # @see Capabilities::Auditable#audit
    #
    def audit( *args )
        if Arachni::Options.exclude_cookies.include?( name )
            auditor.print_info "Skipping audit of '#{name}' cookie."
            return
        end
        super( *args )
    end

    #
    # Indicates whether the cookie must be only sent over an encrypted channel.
    #
    # @return   [Bool]
    #
    def secure?
        @raw['secure'] == true
    end

    #
    # Indicates whether the cookie is safe from modification from client-side code.
    #
    # @return   [Bool]
    #
    def http_only?
        @raw['httponly'] == true
    end

    #
    # Indicates whether the cookie is to be discarded at the end of the session.
    #
    # Doesn't play a role during the scan but it can provide useful info to modules and such.
    #
    # @return   [Bool]
    #
    def session?
        @raw['expires'].nil?
    end

    #
    # @return   [Time, NilClass]    expiration time of the cookie or nil if it
    #                               doesn't have one (i.e. is a session cookie)
    #
    def expires_at
        expires
    end
    #
    # Indicates whether the cookie has expired.
    #
    # @param    [Time]    time    to compare against
    #
    # @return [Boolean]
    #
    def expired?( time = Time.now )
        expires_at != nil && time > expires_at
    end

    #
    # @return   [Hash]    simple representation of the cookie as a hash with the
    #                     value as key and the cookie value as value.
    def simple
        self.auditable.dup
    end

    #
    # @return   [String]    name of the current element, 'cookie' in this case.
    #
    def type
        Arachni::Element::COOKIE
    end

    def dup
        d = super
        d.action = self.action
        d
    end

    #
    # Sets auditable cookie name and value
    #
    # @param    [Hash]  inputs   name => value pair
    #
    def auditable=( inputs )
        k = inputs.keys.first
        v = inputs.values.first

        raw = @raw.dup
        raw['name']  = k
        raw['value'] = v

        @raw = raw.freeze

        if k.to_s.empty?
            super( {} )
        else
            super( { k => v } )
        end
    end

    #
    # Overrides {Capabilities::Mutable#mutations} to handle cookie-specific limitations
    # and the {Arachni::Options#audit_cookies_extensively} option.
    #
    # @see Capabilities::Mutable#mutations
    #
    def mutations( injection_str, opts = {} )
        flip = opts.delete( :param_flip )
        muts = super( injection_str, opts )

        if flip
            elem = self.dup

            # when under HPG mode element auditing is strictly regulated
            # and when we flip params we essentially create a new element
            # which won't be on the whitelist
            elem.override_instance_scope

            elem.altered = 'Parameter flip'
            elem.auditable = { injection_str => seed }
            muts << elem
        end

        if !orphan? && Arachni::Options.audit_cookies_extensively?
            # submit all links and forms of the page along with our cookie mutations
            muts |= muts.map do |m|
                (auditor.page.links | auditor.page.forms).map do |e|
                    next if e.auditable.empty?
                    c = e.dup
                    c.altered = "mutation for the '#{m.altered}' cookie"
                    c.auditor = auditor
                    c.opts[:cookies] = m.auditable.dup
                    c.auditable = Arachni::Module::KeyFiller.fill( c.auditable.dup )
                    c
                end
            end.flatten.compact
        end

        muts
    end

    #
    # Uses the method name as a key to cookie attributes in {DEFAULT}.
    #
    # Like:
    #    cookie.name
    #    cookie.domain
    #
    def method_missing( sym, *args, &block )
        return @raw[sym.to_s] if respond_to?( sym )
        super( sym, *args, &block )
    end

    #
    # Used by {#method_missing} to determine if it should process the call.
    #
    # @return   [Bool]
    #
    def respond_to?( sym )
        @raw.include?( sym.to_s ) || super( sym )
    end

    #
    # @return   [String]    to be used in a 'Cookie' request header. (name=value)
    #
    def to_s
        "#{encode( name )}=#{encode( value )}"
    end

    #
    # Returns an array of cookies from an Netscape HTTP cookiejar file.
    #
    # @example Parsing a Netscape HTTP cookiejar file
    #
    #   # Given a cookie-jar file with the following contents:
    #   #
    #   #   # comment, should be ignored
    #   #   .domain.com	TRUE	/path/to/somewhere	TRUE	Tue, 02 Oct 2012 19:25:57 GMT	first_name	first_value
    #   #
    #   #   # ignored again
    #   #   another-domain.com	FALSE	/	FALSE	second_name	second_value
    #   #
    #   #   # with expiry date as seconds since epoch
    #   #   .blah-domain	TRUE	/	FALSE	1596981560	NAME	OP5jTLV6VhYHADJAbJ1ZR@L8~081210
    #
    #   Cookie.from_file 'http://owner-url.com', 'cookies.jar'
    #   #=> [first_name=first_value, second_name=second_value, NAME=OP5jTLV6VhYHADJAbJ1ZR@L8~081210]
    #
    #   # And here's the fancier dump:
    #   # [
    #   #     [0] #<Arachni::Element::Cookie:0x011636d0
    #   #         attr_accessor :action = "http://owner-url.com/",
    #   #         attr_accessor :auditable = {
    #   #             "first_name" => "first_value"
    #   #         },
    #   #         attr_accessor :method = "get",
    #   #         attr_accessor :url = "http://owner-url.com/",
    #   #         attr_reader :hash = -473180912834263695,
    #   #         attr_reader :opts = {},
    #   #         attr_reader :orig = {
    #   #             "first_name" => "first_value"
    #   #         },
    #   #         attr_reader :raw = {
    #   #                  "domain" => ".domain.com",
    #   #                    "path" => "/path/to/somewhere",
    #   #                  "secure" => true,
    #   #                 "expires" => 2012-10-02 22:25:57 +0300,
    #   #                    "name" => "first_name",
    #   #                   "value" => "first_value",
    #   #                 "version" => 0,
    #   #                    "port" => nil,
    #   #                 "discard" => nil,
    #   #             "comment_url" => nil,
    #   #                 "max_age" => nil,
    #   #                 "comment" => nil,
    #   #                "httponly" => false
    #   #         }
    #   #     >,
    #   #     [1] #<Arachni::Element::Cookie:0x011527b8
    #   #         attr_accessor :action = "http://owner-url.com/",
    #   #         attr_accessor :auditable = {
    #   #             "second_name" => "second_value"
    #   #         },
    #   #         attr_accessor :method = "get",
    #   #         attr_accessor :url = "http://owner-url.com/",
    #   #         attr_reader :hash = -2673771862017142861,
    #   #         attr_reader :opts = {},
    #   #         attr_reader :orig = {
    #   #             "second_name" => "second_value"
    #   #         },
    #   #         attr_reader :raw = {
    #   #                  "domain" => "another-domain.com",
    #   #                    "path" => "/",
    #   #                  "secure" => false,
    #   #                 "expires" => nil,
    #   #                    "name" => "second_name",
    #   #                   "value" => "second_value",
    #   #                 "version" => 0,
    #   #                    "port" => nil,
    #   #                 "discard" => nil,
    #   #             "comment_url" => nil,
    #   #                 "max_age" => nil,
    #   #                 "comment" => nil,
    #   #                "httponly" => false
    #   #         }
    #   #     >,
    #   #     [2] #<Arachni::Element::Cookie:0x011189f0
    #   #         attr_accessor :action = "http://owner-url.com/",
    #   #         attr_accessor :auditable = {
    #   #             "NAME" => "OP5jTLV6VhYHADJAbJ1ZR@L8~081210"
    #   #         },
    #   #         attr_accessor :method = "get",
    #   #         attr_accessor :url = "http://owner-url.com/",
    #   #         attr_reader :hash = 4086929775905476282,
    #   #         attr_reader :opts = {},
    #   #         attr_reader :orig = {
    #   #             "NAME" => "OP5jTLV6VhYHADJAbJ1ZR@L8~081210"
    #   #         },
    #   #         attr_reader :raw = {
    #   #                  "domain" => ".blah-domain",
    #   #                    "path" => "/",
    #   #                  "secure" => false,
    #   #                 "expires" => 2020-08-09 16:59:20 +0300,
    #   #                    "name" => "NAME",
    #   #                   "value" => "OP5jTLV6VhYHADJAbJ1ZR@L8~081210",
    #   #                 "version" => 0,
    #   #                    "port" => nil,
    #   #                 "discard" => nil,
    #   #             "comment_url" => nil,
    #   #                 "max_age" => nil,
    #   #                 "comment" => nil,
    #   #                "httponly" => false
    #   #         }
    #   #     >
    #   # ]
    #
    #
    # @param   [String]    url          request URL
    # @param   [String]    filepath     Netscape HTTP cookiejar file
    #
    # @return   [Array<Cookie>]
    #
    def self.from_file( url, filepath )
        File.open( filepath, 'r' ).map do |line|
            # skip empty lines
            next if (line = line.strip).empty? || line[0] == '#'

            c = {}
            c['domain'], foo, c['path'], c['secure'], c['expires'], c['name'],
                c['value'] = *line.split( "\t" )

            # expiry date is optional so if we don't have one push everything back
            begin
                c['expires'] = expires_to_time( c['expires'] )
            rescue
                c['value'] = c['name'].dup
                c['name'] = c['expires'].dup
                c['expires'] = nil
            end
            c['secure'] = (c['secure'] == 'TRUE') ? true : false
            new( url, c )
        end.flatten.compact
    end

    #
    # Converts a cookie's 'expires' attribute to a Ruby +Time+ object.
    #
    # @example String time format
    #   Cookie.expires_to_time "Tue, 02 Oct 2012 19:25:57 GMT"
    #    #=> 2012-10-02 22:25:57 +0300
    #
    # @example Seconds since Epoch
    #   Cookie.expires_to_time "1596981560"
    #    #=> 2020-08-09 16:59:20 +0300
    #
    #   Cookie.expires_to_time 1596981560
    #    #=> 2020-08-09 16:59:20 +0300
    #
    # @param    [String]    expires
    #
    # @return   [Time]
    #
    def self.expires_to_time( expires )
        (expires_to_i = expires.to_i) > 0 ? Time.at( expires_to_i ) : Time.parse( expires )
    end

    #
    # Returns an array of cookies from an HTTP response.
    #
    #
    # @example
    #    body = <<-HTML
    #        <html>
    #            <head>
    #                <meta http-equiv="Set-Cookie" content="cookie=val; httponly">
    #                <meta http-equiv="Set-Cookie" content="cookie2=val2; Expires=Thu, 01 Jan 1970 00:00:01 GMT; Path=/; Domain=.foo.com; HttpOnly; secure">
    #            </head>
    #        </html>
    #    HTML
    #
    #    response = Typhoeus::Response.new(
    #        body:          body,
    #        effective_url: 'http://stuff.com',
    #        headers_hash:  {
    #           'Set-Cookie' => "coo%40ki+e2=blah+val2%40; Expires=Thu, 01 Jan 1970 00:00:01 GMT; Path=/; Domain=.foo.com; HttpOnly"
    #       }
    #    )
    #
    #    Cookie.from_response response
    #    # [cookie=val, cookie2=val2, coo@ki+e2=blah+val2@]
    #
    #    # Fancy dump:
    #    # [
    #    #     [0] #<Arachni::Element::Cookie:0x028e30f8
    #    #         attr_accessor :action = "http://stuff.com/",
    #    #         attr_accessor :auditable = {
    #    #             "cookie" => "val"
    #    #         },
    #    #         attr_accessor :method = "get",
    #    #         attr_accessor :url = "http://stuff.com/",
    #    #         attr_reader :hash = 2101892390575163651,
    #    #         attr_reader :opts = {},
    #    #         attr_reader :orig = {
    #    #             "cookie" => "val"
    #    #         },
    #    #         attr_reader :raw = {
    #    #                    "name" => "cookie",
    #    #                   "value" => "val",
    #    #                 "version" => 0,
    #    #                    "port" => nil,
    #    #                 "discard" => nil,
    #    #             "comment_url" => nil,
    #    #                 "expires" => nil,
    #    #                 "max_age" => nil,
    #    #                 "comment" => nil,
    #    #                  "secure" => nil,
    #    #                    "path" => "/",
    #    #                  "domain" => "stuff.com",
    #    #                "httponly" => true
    #    #         }
    #    #     >,
    #    #     [1] #<Arachni::Element::Cookie:0x028ec0e0
    #    #         attr_accessor :action = "http://stuff.com/",
    #    #         attr_accessor :auditable = {
    #    #             "cookie2" => "val2"
    #    #         },
    #    #         attr_accessor :method = "get",
    #    #         attr_accessor :url = "http://stuff.com/",
    #    #         attr_reader :hash = 1525536412599744532,
    #    #         attr_reader :opts = {},
    #    #         attr_reader :orig = {
    #    #             "cookie2" => "val2"
    #    #         },
    #    #         attr_reader :raw = {
    #    #                    "name" => "cookie2",
    #    #                   "value" => "val2",
    #    #                 "version" => 0,
    #    #                    "port" => nil,
    #    #                 "discard" => nil,
    #    #             "comment_url" => nil,
    #    #                 "expires" => 1970-01-01 02:00:01 +0200,
    #    #                 "max_age" => nil,
    #    #                 "comment" => nil,
    #    #                  "secure" => true,
    #    #                    "path" => "/",
    #    #                  "domain" => ".foo.com",
    #    #                "httponly" => true
    #    #         }
    #    #     >,
    #    #     [2] #<Arachni::Element::Cookie:0x028ef3f8
    #    #         attr_accessor :action = "http://stuff.com/",
    #    #         attr_accessor :auditable = {
    #    #             "coo@ki e2" => "blah val2@"
    #    #         },
    #    #         attr_accessor :method = "get",
    #    #         attr_accessor :url = "http://stuff.com/",
    #    #         attr_reader :hash = 3179884445716720825,
    #    #         attr_reader :opts = {},
    #    #         attr_reader :orig = {
    #    #             "coo@ki e2" => "blah val2@"
    #    #         },
    #    #         attr_reader :raw = {
    #    #                    "name" => "coo@ki e2",
    #    #                   "value" => "blah val2@",
    #    #                 "version" => 0,
    #    #                    "port" => nil,
    #    #                 "discard" => nil,
    #    #             "comment_url" => nil,
    #    #                 "expires" => 1970-01-01 02:00:01 +0200,
    #    #                 "max_age" => nil,
    #    #                 "comment" => nil,
    #    #                  "secure" => nil,
    #    #                    "path" => "/",
    #    #                  "domain" => ".foo.com",
    #    #                "httponly" => true
    #    #         }
    #    #     >
    #    # ]
    #
    # @param   [Typhoeus::Response]    response
    #
    # @return   [Array<Cookie>]
    #
    # @see from_document
    # @see from_headers
    #
    def self.from_response( response )
        ( from_document( response.effective_url, response.body ) |
         from_headers( response.effective_url, response.headers_hash ) )
    end

    #
    # Returns an array of cookies from a document based on 'Set-Cookie' http-equiv meta tags.
    #
    # @example
    #
    #    body = <<-HTML
    #        <html>
    #            <head>
    #                <meta http-equiv="Set-Cookie" content="cookie=val; httponly">
    #                <meta http-equiv="Set-Cookie" content="cookie2=val2; Expires=Thu, 01 Jan 1970 00:00:01 GMT; Path=/; Domain=.foo.com; HttpOnly; secure">
    #            </head>
    #        </html>
    #    HTML
    #
    #    Cookie.from_document 'http://owner-url.com', body
    #    #=> [cookie=val, cookie2=val2]
    #
    #    Cookie.from_document 'http://owner-url.com', Nokogiri::HTML( body )
    #    #=> [cookie=val, cookie2=val2]
    #
    #    # Fancy dump:
    #    # [
    #    #     [0] #<Arachni::Element::Cookie:0x02a23030
    #    #         attr_accessor :action = "http://owner-url.com/",
    #    #         attr_accessor :auditable = {
    #    #             "cookie" => "val"
    #    #         },
    #    #         attr_accessor :method = "get",
    #    #         attr_accessor :url = "http://owner-url.com/",
    #    #         attr_reader :hash = 1135494168462266792,
    #    #         attr_reader :opts = {},
    #    #         attr_reader :orig = {
    #    #             "cookie" => "val"
    #    #         },
    #    #         attr_reader :raw = {
    #    #                    "name" => "cookie",
    #    #                   "value" => "val",
    #    #                 "version" => 0,
    #    #                    "port" => nil,
    #    #                 "discard" => nil,
    #    #             "comment_url" => nil,
    #    #                 "expires" => nil,
    #    #                 "max_age" => nil,
    #    #                 "comment" => nil,
    #    #                  "secure" => nil,
    #    #                    "path" => "/",
    #    #                  "domain" => "owner-url.com",
    #    #                "httponly" => true
    #    #         }
    #    #     >,
    #    #     [1] #<Arachni::Element::Cookie:0x026745b0
    #    #         attr_accessor :action = "http://owner-url.com/",
    #    #         attr_accessor :auditable = {
    #    #             "cookie2" => "val2"
    #    #         },
    #    #         attr_accessor :method = "get",
    #    #         attr_accessor :url = "http://owner-url.com/",
    #    #         attr_reader :hash = -765632517082248204,
    #    #         attr_reader :opts = {},
    #    #         attr_reader :orig = {
    #    #             "cookie2" => "val2"
    #    #         },
    #    #         attr_reader :raw = {
    #    #                    "name" => "cookie2",
    #    #                   "value" => "val2",
    #    #                 "version" => 0,
    #    #                    "port" => nil,
    #    #                 "discard" => nil,
    #    #             "comment_url" => nil,
    #    #                 "expires" => 1970-01-01 02:00:01 +0200,
    #    #                 "max_age" => nil,
    #    #                 "comment" => nil,
    #    #                  "secure" => true,
    #    #                    "path" => "/",
    #    #                  "domain" => ".foo.com",
    #    #                "httponly" => true
    #    #         }
    #    #     >
    #    # ]
    #
    # @param    [String]    url     owner URL
    # @param    [String, Nokogiri::HTML::Document]    document
    #
    # @return   [Array<Cookie>]
    #
    # @see parse_set_cookie
    #
    def self.from_document( url, document )
        # optimizations in case there are no cookies in the doc,
        # avoid parsing unless absolutely necessary!
        if !document.is_a?( Nokogiri::HTML::Document )
            # get get the head in order to check if it has an http-equiv for set-cookie
            head = document.to_s.match( /<head(.*)<\/head>/imx )

            # if it does feed the head to the parser in order to extract the cookies
            return [] if !head || !head.to_s.downcase.substring?( 'set-cookie' )

            document = Nokogiri::HTML( head.to_s )
        end

        Arachni::Utilities.exception_jail {
            document.search( "//meta[@http-equiv]" ).map do |elem|
                next if elem['http-equiv'].downcase != 'set-cookie'
                parse_set_cookie( url, elem['content'] )
            end.flatten.compact
        } rescue []
    end

    #
    # Returns an array of cookies from a the 'Set-Cookie' header field.
    #
    # @example
    #    Cookie.from_headers 'http://owner-url.com', { 'Set-Cookie' => "coo%40ki+e2=blah+val2%40" }
    #    #=> [coo@ki+e2=blah+val2@]
    #
    #    # Fancy dump:
    #    # [
    #    #     [0] #<Arachni::Element::Cookie:0x01e17250
    #    #         attr_accessor :action = "http://owner-url.com/",
    #    #         attr_accessor :auditable = {
    #    #             "coo@ki e2" => "blah val2@"
    #    #         },
    #    #         attr_accessor :method = "get",
    #    #         attr_accessor :url = "http://owner-url.com/",
    #    #         attr_reader :hash = -1249755840178478661,
    #    #         attr_reader :opts = {},
    #    #         attr_reader :orig = {
    #    #             "coo@ki e2" => "blah val2@"
    #    #         },
    #    #         attr_reader :raw = {
    #    #                    "name" => "coo@ki e2",
    #    #                   "value" => "blah val2@",
    #    #                 "version" => 0,
    #    #                    "port" => nil,
    #    #                 "discard" => nil,
    #    #             "comment_url" => nil,
    #    #                 "expires" => nil,
    #    #                 "max_age" => nil,
    #    #                 "comment" => nil,
    #    #                  "secure" => nil,
    #    #                    "path" => "/",
    #    #                  "domain" => "owner-url.com",
    #    #                "httponly" => false
    #    #         }
    #    #     >
    #    # ]
    #
    # @param    [String]    url     request URL
    # @param    [Hash]      headers
    #
    # @return   [Array<Cookie>]
    #
    # @see forms_set_cookie
    #
    def self.from_headers( url, headers )
        set_strings = []
        headers.each { |k, v| set_strings = [v].flatten if k.downcase == 'set-cookie' }

        return set_strings if set_strings.empty?
        exception_jail {
            set_strings.map { |c| parse_set_cookie( url, c ) }.flatten
        } rescue []
    end

    #
    # Parses a 'set-cookie' string into cookie elements.
    #
    # @example
    #    Cookie.from_set_cookie 'http://owner-url.com', "coo%40ki+e2=blah+val2%40"
    #    #=> [coo@ki+e2=blah+val2@]
    #
    #    # Fancy dump:
    #    # [
    #    #     [0] #<Arachni::Element::Cookie:0x01e17250
    #    #         attr_accessor :action = "http://owner-url.com/",
    #    #         attr_accessor :auditable = {
    #    #             "coo@ki e2" => "blah val2@"
    #    #         },
    #    #         attr_accessor :method = "get",
    #    #         attr_accessor :url = "http://owner-url.com/",
    #    #         attr_reader :hash = -1249755840178478661,
    #    #         attr_reader :opts = {},
    #    #         attr_reader :orig = {
    #    #             "coo@ki e2" => "blah val2@"
    #    #         },
    #    #         attr_reader :raw = {
    #    #                    "name" => "coo@ki e2",
    #    #                   "value" => "blah val2@",
    #    #                 "version" => 0,
    #    #                    "port" => nil,
    #    #                 "discard" => nil,
    #    #             "comment_url" => nil,
    #    #                 "expires" => nil,
    #    #                 "max_age" => nil,
    #    #                 "comment" => nil,
    #    #                  "secure" => nil,
    #    #                    "path" => "/",
    #    #                  "domain" => "owner-url.com",
    #    #                "httponly" => false
    #    #         }
    #    #     >
    #    # ]
    #
    #
    # @param    [String]    url     request URL
    # @param    [Hash]      str     set-cookie string
    #
    # @return   [Array<Cookie>]
    #
    def self.from_set_cookie( url, str )
        WEBrick::Cookie.parse_set_cookies( str ).flatten.uniq.map do |cookie|
            cookie_hash = {}
            cookie.instance_variables.each do |var|
                cookie_hash[var.to_s.gsub( /@/, '' )] = cookie.instance_variable_get( var )
            end
            cookie_hash['expires'] = cookie.expires

            cookie_hash['name']  = decode( cookie.name )
            cookie_hash['value'] = decode( cookie.value )

            new( url.to_s, cookie_hash )
        end.flatten.compact
    end
    def self.parse_set_cookie( *args )
        from_set_cookie( *args )
    end

    #
    # Encodes a {String} in order to prepare it for the Cookie header field.
    #
    # @param    [String]    str
    #
    def self.encode( str )
        URI.encode( str, "+;%=\0" ).gsub( ' ', '+' )
    end
    #
    # Encodes a {String} in order to prepare it for the Cookie header field.
    #
    # @param    [String]    str
    #
    def encode( str )
        self.class.encode( str )
    end

    #
    # Decodes a {String} encoded for the Cookie header field.
    #
    # @param    [String]    str
    #
    def self.decode( str )
        URI.decode( str.gsub( '+', ' ' ) )
    end
    #
    # Decodes a {String} encoded for the Cookie header field.
    #
    # @param    [String]    str
    #
    def decode( str )
        self.class.decode( str )
    end

    private
    def http_request( opts = {}, &block )
        opts[:cookies] = opts[:params].dup
        opts[:params] = {}

        self.method.downcase.to_s != 'get' ?
            http.post( self.action, opts, &block ) : http.get( self.action, opts, &block )
    end

end
end

Arachni::Cookie = Arachni::Element::Cookie
