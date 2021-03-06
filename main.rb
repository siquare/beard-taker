require 'bundler'

Bundler.require

require 'uri'
require 'net/http'
require 'time'
require 'jwt'
require 'json'
require 'pry'
require 'dotenv/load'
require 'line/bot'

BASE_URL = "https://api.quoine.com"
PRODUCT_ID = 5 # BTCJPY
LEVERAGE_LEVEL = 25
LOWER_MARGIN = 0.99
UPPER_MARGIN = 1.01
QUANTITY = 0.1

class APIError < StandardError
end

class Execution
  attr_reader :id, :quantity, :price, :taker_side, :created_at

  def initialize(model)
    @id = model['id']
    @quantity = model['quantity']
    @price = model['price']
    @taker_side = model['taker_side']
    @created_at = Time.at(model['created_at'].to_i)
  end
end

class Order
  attr_reader :id, :order_type, :quantity, :disc_quantity, :iceberg_total_quantity,
    :side, :filled_quantity, :price, :created_at, :updated_at, :status,
    :leverage_level, :source_exchange, :product_id, :product_code, :funding_currency,
    :currency_pair_code

  def initialize(model)
    @id = model['id']
    @status = model['status']
    @created_at = Time.at(model['created_at'].to_i)
    @updated_at = Time.at(model['updated_at'].to_i)
  end
end

class Trade
  attr_reader :id, :pnl, :updated_at, :created_at, :open_price, :side, :stop_loss, :take_profit

  def initialize(model)
    @id = model['id']
    @pnl = model['pnl'].to_f
    @created_at = Time.at(model['created_at'].to_i)
    @updated_at = Time.at(model['updated_at'].to_i)
    @open_price = model['open_price'].to_f
    @side = model['side']
    @stop_loss = model['stop_loss'].to_f
    @take_profit = model['take_profit'].to_f
  end
end

class QuoineAPI
  def self.get_executions_by_timestamp(timestamp)
    STDERR.puts "Quoine API: GET /executions?timestamp=#{timestamp}"

    response = Net::HTTP.get(URI.parse("#{BASE_URL}/executions?product_id=#{PRODUCT_ID}&timestamp=#{timestamp}"))

    STDERR.puts response

    hash = JSON.parse(response)
    hash.map { |model| Execution.new(model) }
  rescue JSON::ParserError => e
    STDERR.puts "#{e.backtrace.first}: #{e.message} (#{e.class})", e.backtrace.drop(1).map { |s| "\t#{s}" }
    raise APIError
  end

  def self.get_orders(status: :live)
    STDERR.puts "Quoine API: GET /orders?status=#{status}"

    path = "/orders?status=#{status}"
    response = request_with_authentication(Net::HTTP::Get, path)

    STDERR.puts response

    hash = JSON.parse(response)
    hash['models'].map { |model| Order.new(model) }
  end

  def self.get_order(id)
    STDERR.puts "Quoine API: GET /orders/#{id}"

    path = "/orders/#{id}"
    response = request_with_authentication(Net::HTTP::Get, path)

    STDERR.puts response

    Order.new(JSON.parse(response))
  end

  def self.create_order(side:, quantity:, price:)
    STDERR.puts "Quoine API: POST /orders?side=#{side}&quantity=#{quantity}&price=#{price}"

    path = "/orders?product_id=#{PRODUCT_ID}"
    response = request_with_authentication(Net::HTTP::Post, path, {
      order_type: 'limit',
      product_id: PRODUCT_ID,
      side: side,
      quantity: quantity,
      price: price,
      leverage_level: LEVERAGE_LEVEL,
      funding_currency: 'JPY'
    })

    STDERR.puts response

    Order.new(JSON.parse(response))
  end

  def self.cancel_order(id)
    STDERR.puts "Quoine API: PUT /orders/#{id}/cancel"

    path = "/orders/#{id}/cancel"
    response = request_with_authentication(Net::HTTP::Put, path)

    STDERR.puts response

    Order.new(JSON.parse(response))
  end

  def self.get_trades(options = { status: :open })
    query = options.map { |key, val| "#{key}=#{val}" }.join('&')

    STDERR.puts "Quoine API: GET /trades?#{query}"

    path = "/trades?#{query}"
    response = request_with_authentication(Net::HTTP::Get, path)

    STDERR.puts response

    hash = JSON.parse(response)
    hash['models'].map { |model| Trade.new(model) }
  end

  def self.close_trade(id)
    STDERR.puts "Quoine API: PUT /trades/#{id}/close"

    path = "/trades/#{id}/close"
    response = request_with_authentication(Net::HTTP::Put, path)

    STDERR.puts response

    Trade.new(JSON.parse(response))
  end

  # params = { take_profit: 1 << 30, stop_loss: 0 }
  def self.update_trade(id, params)
    STDERR.puts "Quoine API: PUT /trades/#{id}"

    path = "/trades/#{id}"
    response = request_with_authentication(Net::HTTP::Put, path, body = params.to_json)

    STDERR.puts response

    Trade.new(JSON.parse(response))
  end

  def self.request_with_authentication(http_request, path, body = "")
    uri = URI.parse(BASE_URL)
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true

    token_id = ENV['QUOINE_TOKEN_ID']
    user_secret = ENV['QUOINE_TOKEN_SECRET']

    auth_payload = {
      path: path,
      nonce: DateTime.now.strftime('%Q'),
      token_id: token_id
    }

    signature = JWT.encode(auth_payload, user_secret, 'HS256')

    request = http_request.new(path)
    request.add_field('X-Quoine-API-Version', '2')
    request.add_field('X-Quoine-Auth', signature)
    request.add_field('Content-Type', 'application/json')
    request.body = (body.is_a?(String) ? body : body.to_json)

    response = http.request(request)

    if response.code != "200"
      STDERR.puts "Code: #{response.code}"
      STDERR.puts "Body: #{response.body}"
      raise APIError
    end

    response.body
  end
end

class LineAPI
  @client ||= Line::Bot::Client.new do |config|
    config.channel_secret = ENV['LINE_CHANNEL_SECRET']
    config.channel_token = ENV['LINE_CHANNEL_TOKEN']
  end

  def self.report_trade(trade)
    @client.push_message(ENV['LINE_USER_ID'], {
       type: 'text',
       text: "#{Time.now.strftime('%Y/%m/%d %H:%M:%S')}: Closed #{trade.side} position with #{trade.pnl} pnl."
     })
  end

  def self.send_alert(text)
    @client.push_message(ENV['LINE_USER_ID'], { type: 'text', text: text })
  end

  def self.report_trades(start_time, trades)
    duration = "#{start_time.strftime('%Y/%m/%d %H:%M:%S')} ~ #{Time.now.strftime('%Y/%m/%d %H:%M:%S')}"
    total_pnl = trades.map(&:pnl).sum

    @client.push_message(ENV['LINE_USER_ID'], {
      type: 'text',
      text: "Duration: #{duration}\nTotal pnl: #{total_pnl}"
    })
  end
end

def main
  locked_untill = Time.now - 1
  started_at = Time.now

  loop do
    current_time = Time.now

    if locked_untill > Time.now
      sleep(locked_untill - Time.now)
      next
    end

    executions = QuoineAPI.get_executions_by_timestamp(current_time.to_i - 60)
    prices = executions.map(&:price)

    if prices.empty?
      sleep(60)
      next
    end

    order_price_min = prices.first * LOWER_MARGIN
    order_price_max = prices.first * UPPER_MARGIN

    QuoineAPI.create_order(side: 'buy',  quantity: QUANTITY, price: order_price_min)
    # QuoineAPI.create_order(side: 'buy',  quantity: QUANTITY, price: prices.min * 0.99)
    QuoineAPI.create_order(side: 'sell', quantity: QUANTITY, price: order_price_max)

    sleep(60)

    QuoineAPI.get_orders.each do |order|
      QuoineAPI.cancel_order(order.id)
    end

    QuoineAPI.get_trades.each do |trade|
      if trade.side == 'long'
        QuoineAPI.update_trade(trade.id, { take_profit: trade.open_price / LOWER_MARGIN })
      end

      if trade.side == 'short'
        QuoineAPI.update_trade(trade.id, { take_profit: trade.open_price / UPPER_MARGIN })
      end

      # will_close_at = trade.updated_at + 60

      Thread.new do
        # sleep(will_close_at - Time.now)
        sleep(60)

        trade = QuoineAPI.close_trade(trade.id)

        LineAPI.report_trade(trade)

        # Lock 10 minitues to avoid the great slump.
        if trade.pnl < 0
          locked_untill = Time.now + 600
        end
      end
    end
  end
rescue Interrupt
  puts "Interrupted."
rescue APIError
  STDERR.puts "APIError occured. Sleep 60 seconds."
  sleep(60)
  retry
rescue => e
  LineAPI.send_alert("#{e.backtrace.first}: #{e.message} (#{e.class})", e.backtrace.drop(1).map{|s| "\t#{s}"})

  raise e
ensure
  puts 'Cancelling all orders ...'

  QuoineAPI.get_orders.each do |order|
    QuoineAPI.cancel_order(order.id)
  end

  puts 'Closing all trades ...'

  QuoineAPI.get_trades.each do |trade|
    QuoineAPI.close_trade(trade.id)
  end

  trades = QuoineAPI.get_trades(limit: 1<<30).select { |trade| trade.created_at > started_at }

  LineAPI.report_trades(started_at, trades)
end

main
