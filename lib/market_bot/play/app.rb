module MarketBot
  module Play
    class App
      attr_reader(*ATTRIBUTES)
      attr_reader :package
      attr_reader :lang
      attr_reader :result

      def self.parse(html, _opts = {})
        result = {}

        doc = Nokogiri::HTML(html)

        result[:website_url]      = doc.xpath("//div[contains(text(), 'Website')]")&.first&.next&.text
        result[:email]            = doc.xpath("//div[contains(text(), 'Email')]")&.first&.next&.text
        result[:physical_address] = doc.xpath("//div[contains(text(), 'Address')]")&.first&.next&.text
        result[:privacy_url]      = doc.xpath("//div[contains(text(), 'Privacy policy')]")&.first&.next&.text
        result[:updated]          = doc.xpath("//div[contains(text(), 'Updated on')]")&.first&.next&.text
        result[:title]            = doc.at_css('h1[itemprop="name"]').text
        result[:description]      = doc.at_css('meta[itemprop="description"]')&.next&.inner_html&.strip
        result[:contains_ads]     = !!doc.at('div:contains("Contains ads")')

        a_similar = doc.at_css('h2:contains("Similar apps")')
        if a_similar
          similar_divs     = a_similar.ancestors('header')&.first&.next&.children&.children
          result[:similar] = similar_divs.search('a')
                                         .select { |a| a['href'].start_with?('/store/apps/details') }
                                         .map { |a| { package: a['href'].split('?id=').last.strip } }
                                         .compact.uniq
        end

        a_dev                  = doc.css("//a[@href*='/store/apps/dev']")
        result[:developer]     = a_dev.text
        result[:developer_url] = a_dev.attr('href')&.value
        result[:developer_id]  = result[:developer_url]&.split('?id=')&.last&.strip

        cdata = doc.at_css('script[type="application/ld+json"]').children.find{|e| e.cdata?}
        cdata_json = JSON.parse(cdata.to_s, {symbolize_names: true})
        aggregate_rating = cdata_json[:aggregateRating]
        if aggregate_rating
          result[:rating] = aggregate_rating[:ratingValue]
          result[:votes]  = aggregate_rating[:ratingCount].to_i
        end
        result[:category] = cdata_json[:applicationCategory]

        h2_more = doc.at_css("h2:contains(\"#{result[:developer]}\")")
        if h2_more
          more_divs = h2_more.ancestors('header')&.first&.next&.children&.children
          if more_divs
            result[:more_from_developer] = more_divs.children.search('a')
                                                    .select { |a| a['href'].start_with?('/store/apps/details') }
                                                    .map { |a| { package: a['href'].split('?id=').last.strip } }
                                                    .compact.uniq
          end
        end

        node = doc.at_css('img[alt="Icon image"]')
        result[:cover_image_url] = MarketBot::Util.fix_content_url(node[:src]) if node.present?

        nodes = doc.search('img[alt="Screenshot image"]', 'img[alt="Screenshot"]')
        result[:screenshot_urls] = []
        if nodes.present?
          result[:screenshot_urls] = nodes.map do |n|
            MarketBot::Util.fix_content_url(n[:src])
          end
        end

        node               = doc.at_css('h2:contains("What\'s new")')&.ancestors('header')&.first&.next&.children
        result[:whats_new] = node.inner_html if node

        result[:html] = html

        result
      end

      def initialize(package, opts = {})
        @package      = package
        @lang         = opts[:lang] || MarketBot::Play::DEFAULT_LANG
        @country      = opts[:country] || MarketBot::Play::DEFAULT_COUNTRY
        @request_opts = MarketBot::Util.build_request_opts(opts[:request_opts])
      end

      def store_url
        "https://play.google.com/store/apps/details?id=#{@package}&hl=#{@lang}&gl=#{@country}"
      end

      def update
        req = Typhoeus::Request.new(store_url, @request_opts)
        req.run
        response_handler(req.response)

        self
      end

      private

      def response_handler(response)
        if response.success?
          @result = self.class.parse(response.body)

          ATTRIBUTES.each do |a|
            attr_name  = "@#{a}"
            attr_value = @result[a]
            instance_variable_set(attr_name, attr_value)
          end
        else
          codes = "code=#{response.code}, return_code=#{response.return_code}"
          case response.code
          when 404
            raise MarketBot::NotFoundError, "Unable to find app in store: #{codes}"
          when 403
            raise MarketBot::UnavailableError, "Unavailable app (country restriction?): #{codes}"
          else
            raise MarketBot::ResponseError, "Unhandled response: #{codes}"
          end
        end
      end
    end
  end
end
