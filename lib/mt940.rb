require 'date'
require 'bigdecimal'
require 'mt940/customer_statement_message'

class MT940

  class AbstractField
    @bankType = :generic
    @@subclasses = { }
    [:generic,:BPH,:Alior].each {|n|@@subclasses[n] = {}}       #registering bankNames

    class << self

      def for(line,bankType)
        if line.match(/^:(\d{2,2})(\w)?:(.*)/m)
          number, modifier, content = $1, $2, $3
          klass =  AbstractField.class_from_number(number.to_i,bankType)
          raise StandardError, "Field #{number} is not implemented" unless klass
          f = klass.new(modifier, content)
        else
          raise StandardError, "Wrong line format: #{line.dump}"
        end
      end

      def register_class (number,*bankType)
        if bankType.empty?
          @@subclasses[:generic][number] = self
        else
          bankType.each{|b| @@subclasses[b][number] = self}
        end
      end

      def class_from_number (number,bankType)
        if !@@subclasses[bankType][number].nil?
          @@subclasses[bankType][number]
        else
          @@subclasses[:generic][number]
        end
      end

    end
  end

  class Field < AbstractField
    attr_reader :modifier, :content

    DATE = /(\d{2})(\d{2})(\d{2})/
    DATE_TIME = /(\d{2})(\d{2})(\d{2})(\d{2})(\d{2})/
    SHORT_DATE = /(\d{2})(\d{2})/

    # I don't like how inheritance is overused here just so every class is
    # initiated in the same way.
    #
    # Also I do not like the way that all the parsing is done upfront. I think
    # a lazier approach should be used.

    def initialize(modifier, content)
      @modifier = modifier
      parse_content(content)
    end

    private
      def parse_amount_in_cents(amount)
        # don't use Integer(amount) function, because amount can be "008" - interpreted as octal number ("010" = 8)
        amount.gsub(',', '').to_i
      end

      def parse_date(date)
        date.match(DATE)
        Date.new("20#{$1}".to_i, $2.to_i, $3.to_i)
      end

    def parse_date_time(date_time)
      date_time.match(DATE_TIME)
      DateTime.new("20#{$1}".to_i, $2.to_i, $3.to_i,$4.to_i, $5.to_i)
    end

      def parse_entry_date(raw_entry_date, value_date)
        raw_entry_date.match(SHORT_DATE)
        entry_date = Date.new(value_date.year, $1.to_i, $2.to_i)
        if (entry_date.year != value_date.year)
          raise "Unhandled case: value date and entry date are in different years"
        end
        entry_date
      end
  end

  # 13
  class DateTimeIndication < Field
    attr_reader :date_time
    register_class 13

    def parse_content(content)
      @date_time = parse_date_time(content)
    end
  end

  # 20
  class Job < Field
    attr_reader :reference
    register_class 20

    def parse_content(content)
      @reference = content
    end
  end

  # 21
  class Reference < Job
    register_class 21
  end

  # 25
  class AccountIdentification < AbstractField
    attr_reader :account_identifier
    register_class 25
    MATCHER_REGEX = /(.{1,35})/ #any 35 chars (35x from the docs)

    def initialize(modifier, content)
      @modifier = modifier
      @content = content
      parse_content(content)
    end

    def parse_content(content)
      @account_identifier = content.match(MATCHER_REGEX)[1]
    end

    # fail over to the old Account class
    def method_missing(method, *args, &block)
      @fail_over_implementation ||= Account.new(@modifier, @content)
      @fail_over_implementation.send(method)
    end
  end


  class Account < Field
    #This is not how field 25 behaves
    #The documentation states that the contents of this field is
    #
    #  35x
    #
    #so you can only attribute a account number (usually as a IBAN).
    attr_reader :bank_code, :account_number, :account_currency

    CONTENT = /^(.{8,11})\/(\d{0,23})([A-Z]{3})?$/

    def parse_content(content)
      warn "MT940::Account should be deprecated"
      content.match(CONTENT)
      @bank_code, @account_number, @account_currency = $1, $2, $3
    end
  end

  # 28
  class StatementNumber <AbstractField
    attr_reader :number, :sequence
    register_class 28

    MATCHER_REGEX = /\d{1,5} (?: \/ \d{1,5})/ # 5n[/5n]

    def initialize(modifier, content)
      @modifier = modifier
      @content = content
      parse_content(content)
    end

    def parse_content(content)
      @number, @sequence = content.split('/')
    end

  end

  class Statement < Field
    attr_reader :number, :sheet

    CONTENT = /^(0|(\d{5,5})\/(\d{2,5}))$/

    def parse_content(content)
      warn 'MT940::Statement is deprecated'
      content.match(CONTENT)
      if $1 == '0'
        @number = @sheet = 0
      else
        @number, @sheet = $2.to_i, $3.to_i
      end
    end
  end

  class AccountBalance < Field
    #This needs to be refactored.
    attr_reader :balance_type, :sign, :currency, :amount, :date

    CONTENT = /^(C|D)(\w{6})(\w{3})(\d{1,12},\d{0,2})$/

    def parse_content(content)
      content.match(CONTENT)

      @balance_type = case @modifier
        when 'F'
          :start
        when 'M'
          :intermediate
      end

      @sign = case $1
        when 'C'
          :credit
        when 'D'
          :debit
      end

      raw_date = $2

      @currency = $3

      amount_str = $4.gsub(/,/, '.')
      @amount = BigDecimal.new(amount_str)

      @date = case raw_date
        when 'ALT', '0'
          nil
        when DATE
          Date.new("20#{$1}".to_i, $2.to_i, $3.to_i)
      end
    end
  end

  # 61
  class StatementLine < Field
    attr_reader :date, :entry_date, :funds_code, :amount, :swift_code, :reference, :transaction_description
    register_class 61

    CONTENT = /^(\d{6})(\d{4})?(C|D|RC|RD)\D?(\d{1,12},\d{0,2})((?:N|F).{3})(NONREF|.{0,16})(?:$|\/\/)(.*)/

    def parse_content(content)
      content.match(CONTENT)

      raw_date = $1
      raw_entry_date = $2
      @funds_code = case $3
        when 'C'
          :credit
        when 'D'
          :debit
        when 'RC'
          :return_credit
        when 'RD'
          :return_debit
      end
      amount_str = $4.gsub(/,/, '.')
      @amount = BigDecimal.new(amount_str)
      
      @swift_code = $5
      @reference = $6
      @transaction_description = $7

      @date = parse_date(raw_date)
      @entry_date = parse_entry_date(raw_entry_date, @date) if raw_entry_date
    end

    def value_date
      @date
    end
  end

  # 60
  class OpeningBalance < AccountBalance
    register_class 60
  end

  # 62
  class ClosingBalance < AccountBalance
    register_class 62
  end

  # 64
  class ValutaBalance < AccountBalance
    register_class 64
  end

  # 65
  class FutureValutaBalance < AccountBalance
    register_class 65
  end

  # 86
  class InformationToAccountOwner <AbstractField
    attr_reader :narrative
    register_class 86

    def initialize(modifier, content)
      @modifier = modifier
      @content = content
      parse_content(content)
    end

    def parse_content(content)
      @narrative = content.split(/\n/).map(&:strip).reject do |line|
        line.empty? || line == '-'
      end
    end

    #Failover to StatementLineInformation
    def method_missing(method, *args, &block)
      @fail_over_implementation ||= StatementLineInformation.new(@modifier, @content)
      @fail_over_implementation.send(method)
    end
  end

  # 86  for Alior
  class AliorInformationToAccountOwner <InformationToAccountOwner
    attr_reader :operation_code
    register_class 86,:Alior

    def parse_content(content)
      @narrative = content.split(/\n/).map(&:strip).reject do |line|
        line.empty? || line == '-'
      end
      @operation_code = @narrative[0][0..3]
      @narrative[0] =  @narrative[0][4..-1]
     # @content = ""
     # @narrative.each{|l| @content << l}
    end

    #Failover to StatementLineInformation
    def method_missing(method, *args, &block)
      @fail_over_implementation ||= AliorStatementLineInformation.new(@modifier, @content)
      @fail_over_implementation.send(method)
    end
  end

  # 90
  class NumberAndSumOfEntries < Field
    attr_reader :number,:currency,:sum
    register_class 90

    CONTENT = /^(\d+)(\w{3})(\d{1,12}\.\d{0,2})$/

    def parse_content(content)
        content.match(CONTENT)
        @number = $1.to_i
        @currency = $2
        @sum = BigDecimal.new($3)
    end
  end

  class StatementLineInformation < Field
    # This class again is doing too much and appears to be specific to a
    # particular implementation and does not appear to follow the swift standard.
    attr_reader :code, :transaction_description, :prima_nota, :details, :bank_code, :account_number,
      :account_holder, :text_key_extension, :not_implemented_fields, :account_identifier

    def parse_content(content)
      warn 'StatementLineInformation should be deprecated'
      content.match(/^(\d{3})((.).*)\s/)
      @code = $1.to_i

      details = []
      account_holder = []

      if seperator = $3
        sub_fields = $2.scan(/#{Regexp.escape(seperator)}(\d{2})([^#{Regexp.escape(seperator)}]*)/)


        sub_fields.each do |(code, content)|
          case code.to_i
            when 0
              @transaction_description = content
            when 10
              @prima_nota = content
            when 20..25
              details << content
            when 26
              @account_identifier = content
            when 30
              @bank_code = content
            when 31
              @account_number = content
            when 32..33
              account_holder << content
            when 34
              @text_key_extension = content
          else
            @not_implemented_fields ||= []
            @not_implemented_fields << [code, content]
            $stderr << "code not implemented: code:#{code} content: \"#{content}\"\n" if $DEBUG

          end
        end
      end

      @details = details.join("\n")
      @account_holder = account_holder.join("\n")
    end
  end


  class AliorStatementLineInformation < Field
    # This class again is doing too much and appears to be specific to a
    # particular implementation and does not appear to follow the swift standard.
    attr_reader :code, :transaction_description, :prima_nota, :details, :bank_code, :account_number,
                :account_holder, :text_key_extension, :not_implemented_fields, :date, :account_identifier

    def parse_content(content)
      warn 'StatementLineInformation should be deprecated'
      content.match(/^(\d{4})((.)[\s\S]*)$/)
      @code = $1.to_i

      details = []
      account_holder = []

      if seperator = $3
        sub_fields = $2.scan(/#{Regexp.escape(seperator)}(\d{2})([^#{Regexp.escape(seperator)}]*)/)


        sub_fields.each do |(code, content)|
          case code.to_i
            when 0
              @transaction_description = content
            when 10
              @prima_nota = content
            when 20..25
              details << content
            when 26
              @date = content
            when 27..28
              account_holder << content
            when 30
              @bank_code = content
            when 31
              @account_number = content
            when 34
              @text_key_extension = content
            when 38
              @account_identifier = content
            else
              @not_implemented_fields ||= []
              @not_implemented_fields << [code, content]
              $stderr << "code not implemented: code:#{code} content: \"#{content}\"\n" if $DEBUG

          end
        end
      end

      @details = details.join("\n")
      @account_holder = account_holder.join("\n")
    end
  end


  class << self
    def parse_bank(text, type)
      @bank_type = type
      strip = text.clone.strip
      stripped = strip
      if @bank_type == :Alior #Removind starting and trailing curly brackets that occurs in Alior MT940 file
        stripped[0,1] = ''
        stripped[-1,2] = ''
      end
      stripped << "\r\n" if stripped[-1,1] == '-'
      raw_sheets = stripped.split(/^-\r\n/).map { |sheet| sheet.gsub(/\r\n(?!:)/, '') }
      raw_sheets.map { |raw_sheet| parse_sheet(raw_sheet) }
    end

    def parse(text)
      parse_bank(text, :BPH)
    end


    private
    def parse_sheet(sheet)
      lines = sheet.split(/\r?\n\s*(?=:)/)
      fields = lines.reject { |line| line.empty? }.map { |line| AbstractField.for(line,@bank_type) }
      fields
    end
  end
end
