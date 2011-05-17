class JsonKpeg::Parser
# STANDALONE START
    def setup_parser(str, debug=false)
      @string = str
      @pos = 0
      @memoizations = Hash.new { |h,k| h[k] = {} }
      @result = nil
      @failed_rule = nil
      @failing_rule_offset = -1

      setup_foreign_grammar
    end

    # This is distinct from setup_parser so that a standalone parser
    # can redefine #initialize and still have access to the proper
    # parser setup code.
    #
    def initialize(str, debug=false)
      setup_parser(str, debug)
    end

    attr_reader :string
    attr_reader :failing_rule_offset
    attr_accessor :result, :pos

    # STANDALONE START
    def current_column(target=pos)
      if c = string.rindex("\n", target-1)
        return target - c - 1
      end

      target + 1
    end

    def current_line(target=pos)
      cur_offset = 0
      cur_line = 0

      string.each_line do |line|
        cur_line += 1
        cur_offset += line.size
        return cur_line if cur_offset >= target
      end

      -1
    end

    def lines
      lines = []
      string.each_line { |l| lines << l }
      lines
    end

    #

    def get_text(start)
      @string[start..@pos-1]
    end

    def show_pos
      width = 10
      if @pos < width
        "#{@pos} (\"#{@string[0,@pos]}\" @ \"#{@string[@pos,width]}\")"
      else
        "#{@pos} (\"... #{@string[@pos - width, width]}\" @ \"#{@string[@pos,width]}\")"
      end
    end

    def failure_info
      l = current_line @failing_rule_offset
      c = current_column @failing_rule_offset

      if @failed_rule.kind_of? Symbol
        info = self.class::Rules[@failed_rule]
        "line #{l}, column #{c}: failed rule '#{info.name}' = '#{info.rendered}'"
      else
        "line #{l}, column #{c}: failed rule '#{@failed_rule}'"
      end
    end

    def failure_caret
      l = current_line @failing_rule_offset
      c = current_column @failing_rule_offset

      line = lines[l-1]
      "#{line}\n#{' ' * (c - 1)}^"
    end

    def failure_character
      l = current_line @failing_rule_offset
      c = current_column @failing_rule_offset
      lines[l-1][c-1, 1]
    end

    def failure_oneline
      l = current_line @failing_rule_offset
      c = current_column @failing_rule_offset

      char = lines[l-1][c-1, 1]

      if @failed_rule.kind_of? Symbol
        info = self.class::Rules[@failed_rule]
        "@#{l}:#{c} failed rule '#{info.name}', got '#{char}'"
      else
        "@#{l}:#{c} failed rule '#{@failed_rule}', got '#{char}'"
      end
    end

    class ParseError < RuntimeError
    end

    def raise_error
      raise ParseError, failure_oneline
    end

    def show_error(io=STDOUT)
      error_pos = @failing_rule_offset
      line_no = current_line(error_pos)
      col_no = current_column(error_pos)

      io.puts "On line #{line_no}, column #{col_no}:"

      if @failed_rule.kind_of? Symbol
        info = self.class::Rules[@failed_rule]
        io.puts "Failed to match '#{info.rendered}' (rule '#{info.name}')"
      else
        io.puts "Failed to match rule '#{@failed_rule}'"
      end

      io.puts "Got: #{string[error_pos,1].inspect}"
      line = lines[line_no-1]
      io.puts "=> #{line}"
      io.print(" " * (col_no + 3))
      io.puts "^"
    end

    def set_failed_rule(name)
      if @pos > @failing_rule_offset
        @failed_rule = name
        @failing_rule_offset = @pos
      end
    end

    attr_reader :failed_rule

    def match_string(str)
      len = str.size
      if @string[pos,len] == str
        @pos += len
        return str
      end

      return nil
    end

    def scan(reg)
      if m = reg.match(@string[@pos..-1])
        width = m.end(0)
        @pos += width
        return true
      end

      return nil
    end

    if "".respond_to? :getbyte
      def get_byte
        if @pos >= @string.size
          return nil
        end

        s = @string.getbyte @pos
        @pos += 1
        s
      end
    else
      def get_byte
        if @pos >= @string.size
          return nil
        end

        s = @string[@pos]
        @pos += 1
        s
      end
    end

    def parse(rule=nil)
      if !rule
        _root ? true : false
      else
        # This is not shared with code_generator.rb so this can be standalone
        method = rule.gsub("-","_hyphen_")
        __send__("_#{method}") ? true : false
      end
    end

    class LeftRecursive
      def initialize(detected=false)
        @detected = detected
      end

      attr_accessor :detected
    end

    class MemoEntry
      def initialize(ans, pos)
        @ans = ans
        @pos = pos
        @uses = 1
        @result = nil
      end

      attr_reader :ans, :pos, :uses, :result

      def inc!
        @uses += 1
      end

      def move!(ans, pos, result)
        @ans = ans
        @pos = pos
        @result = result
      end
    end

    def external_invoke(other, rule, *args)
      old_pos = @pos
      old_string = @string

      @pos = other.pos
      @string = other.string

      begin
        if val = __send__(rule, *args)
          other.pos = @pos
          other.result = @result
        else
          other.set_failed_rule "#{self.class}##{rule}"
        end
        val
      ensure
        @pos = old_pos
        @string = old_string
      end
    end

    def apply_with_args(rule, *args)
      memo_key = [rule, args]
      if m = @memoizations[memo_key][@pos]
        m.inc!

        prev = @pos
        @pos = m.pos
        if m.ans.kind_of? LeftRecursive
          m.ans.detected = true
          return nil
        end

        @result = m.result

        return m.ans
      else
        lr = LeftRecursive.new(false)
        m = MemoEntry.new(lr, @pos)
        @memoizations[memo_key][@pos] = m
        start_pos = @pos

        ans = __send__ rule, *args

        m.move! ans, @pos, @result

        # Don't bother trying to grow the left recursion
        # if it's failing straight away (thus there is no seed)
        if ans and lr.detected
          return grow_lr(rule, args, start_pos, m)
        else
          return ans
        end

        return ans
      end
    end

    def apply(rule)
      if m = @memoizations[rule][@pos]
        m.inc!

        prev = @pos
        @pos = m.pos
        if m.ans.kind_of? LeftRecursive
          m.ans.detected = true
          return nil
        end

        @result = m.result

        return m.ans
      else
        lr = LeftRecursive.new(false)
        m = MemoEntry.new(lr, @pos)
        @memoizations[rule][@pos] = m
        start_pos = @pos

        ans = __send__ rule

        m.move! ans, @pos, @result

        # Don't bother trying to grow the left recursion
        # if it's failing straight away (thus there is no seed)
        if ans and lr.detected
          return grow_lr(rule, nil, start_pos, m)
        else
          return ans
        end

        return ans
      end
    end

    def grow_lr(rule, args, start_pos, m)
      while true
        @pos = start_pos
        @result = m.result

        if args
          ans = __send__ rule, *args
        else
          ans = __send__ rule
        end
        return nil unless ans

        break if @pos <= m.pos

        m.move! ans, @pos, @result
      end

      @result = m.result
      @pos = m.pos
      return m.ans
    end

    class RuleInfo
      def initialize(name, rendered)
        @name = name
        @rendered = rendered
      end

      attr_reader :name, :rendered
    end

    def self.rule_info(name, rendered)
      RuleInfo.new(name, rendered)
    end

    #


  require "json-kpeg/escaper"
  include JsonKpeg::StringEscaper
  
  attr_reader :result
  attr_accessor :strict


  def setup_foreign_grammar; end

  # value = (object | array | string | number | "true" { true } | "false" { false } | "null" { nil })
  def _value

    _save = self.pos
    while true # choice
      _tmp = apply(:_object)
      break if _tmp
      self.pos = _save
      _tmp = apply(:_array)
      break if _tmp
      self.pos = _save
      _tmp = apply(:_string)
      break if _tmp
      self.pos = _save
      _tmp = apply(:_number)
      break if _tmp
      self.pos = _save

      _save1 = self.pos
      while true # sequence
        _tmp = match_string("true")
        unless _tmp
          self.pos = _save1
          break
        end
        @result = begin;  true ; end
        _tmp = true
        unless _tmp
          self.pos = _save1
        end
        break
      end # end sequence

      break if _tmp
      self.pos = _save

      _save2 = self.pos
      while true # sequence
        _tmp = match_string("false")
        unless _tmp
          self.pos = _save2
          break
        end
        @result = begin;  false ; end
        _tmp = true
        unless _tmp
          self.pos = _save2
        end
        break
      end # end sequence

      break if _tmp
      self.pos = _save

      _save3 = self.pos
      while true # sequence
        _tmp = match_string("null")
        unless _tmp
          self.pos = _save3
          break
        end
        @result = begin;  nil ; end
        _tmp = true
        unless _tmp
          self.pos = _save3
        end
        break
      end # end sequence

      break if _tmp
      self.pos = _save
      break
    end # end choice

    set_failed_rule :_value unless _tmp
    return _tmp
  end

  # object = ("{" - "}" { {} } | "{" - object-body:obj - "}" { obj })
  def _object

    _save = self.pos
    while true # choice

      _save1 = self.pos
      while true # sequence
        _tmp = match_string("{")
        unless _tmp
          self.pos = _save1
          break
        end
        _tmp = apply(:__hyphen_)
        unless _tmp
          self.pos = _save1
          break
        end
        _tmp = match_string("}")
        unless _tmp
          self.pos = _save1
          break
        end
        @result = begin;  {} ; end
        _tmp = true
        unless _tmp
          self.pos = _save1
        end
        break
      end # end sequence

      break if _tmp
      self.pos = _save

      _save2 = self.pos
      while true # sequence
        _tmp = match_string("{")
        unless _tmp
          self.pos = _save2
          break
        end
        _tmp = apply(:__hyphen_)
        unless _tmp
          self.pos = _save2
          break
        end
        _tmp = apply(:_object_hyphen_body)
        obj = @result
        unless _tmp
          self.pos = _save2
          break
        end
        _tmp = apply(:__hyphen_)
        unless _tmp
          self.pos = _save2
          break
        end
        _tmp = match_string("}")
        unless _tmp
          self.pos = _save2
          break
        end
        @result = begin;  obj ; end
        _tmp = true
        unless _tmp
          self.pos = _save2
        end
        break
      end # end sequence

      break if _tmp
      self.pos = _save
      break
    end # end choice

    set_failed_rule :_object unless _tmp
    return _tmp
  end

  # object-body = object-pair:x (- "," - object-pair)*:xs { Hash[[x].concat(xs)] }
  def _object_hyphen_body

    _save = self.pos
    while true # sequence
      _tmp = apply(:_object_hyphen_pair)
      x = @result
      unless _tmp
        self.pos = _save
        break
      end
      _ary = []
      while true

        _save2 = self.pos
        while true # sequence
          _tmp = apply(:__hyphen_)
          unless _tmp
            self.pos = _save2
            break
          end
          _tmp = match_string(",")
          unless _tmp
            self.pos = _save2
            break
          end
          _tmp = apply(:__hyphen_)
          unless _tmp
            self.pos = _save2
            break
          end
          _tmp = apply(:_object_hyphen_pair)
          unless _tmp
            self.pos = _save2
          end
          break
        end # end sequence

        _ary << @result if _tmp
        break unless _tmp
      end
      _tmp = true
      @result = _ary
      xs = @result
      unless _tmp
        self.pos = _save
        break
      end
      @result = begin;  Hash[[x].concat(xs)] ; end
      _tmp = true
      unless _tmp
        self.pos = _save
      end
      break
    end # end sequence

    set_failed_rule :_object_hyphen_body unless _tmp
    return _tmp
  end

  # object-pair = string:k - ":" - value:v { [k, v] }
  def _object_hyphen_pair

    _save = self.pos
    while true # sequence
      _tmp = apply(:_string)
      k = @result
      unless _tmp
        self.pos = _save
        break
      end
      _tmp = apply(:__hyphen_)
      unless _tmp
        self.pos = _save
        break
      end
      _tmp = match_string(":")
      unless _tmp
        self.pos = _save
        break
      end
      _tmp = apply(:__hyphen_)
      unless _tmp
        self.pos = _save
        break
      end
      _tmp = apply(:_value)
      v = @result
      unless _tmp
        self.pos = _save
        break
      end
      @result = begin;  [k, v] ; end
      _tmp = true
      unless _tmp
        self.pos = _save
      end
      break
    end # end sequence

    set_failed_rule :_object_hyphen_pair unless _tmp
    return _tmp
  end

  # array = ("[" - "]" { [] } | "[" - array-body:arr - "]" { arr })
  def _array

    _save = self.pos
    while true # choice

      _save1 = self.pos
      while true # sequence
        _tmp = match_string("[")
        unless _tmp
          self.pos = _save1
          break
        end
        _tmp = apply(:__hyphen_)
        unless _tmp
          self.pos = _save1
          break
        end
        _tmp = match_string("]")
        unless _tmp
          self.pos = _save1
          break
        end
        @result = begin;  [] ; end
        _tmp = true
        unless _tmp
          self.pos = _save1
        end
        break
      end # end sequence

      break if _tmp
      self.pos = _save

      _save2 = self.pos
      while true # sequence
        _tmp = match_string("[")
        unless _tmp
          self.pos = _save2
          break
        end
        _tmp = apply(:__hyphen_)
        unless _tmp
          self.pos = _save2
          break
        end
        _tmp = apply(:_array_hyphen_body)
        arr = @result
        unless _tmp
          self.pos = _save2
          break
        end
        _tmp = apply(:__hyphen_)
        unless _tmp
          self.pos = _save2
          break
        end
        _tmp = match_string("]")
        unless _tmp
          self.pos = _save2
          break
        end
        @result = begin;  arr ; end
        _tmp = true
        unless _tmp
          self.pos = _save2
        end
        break
      end # end sequence

      break if _tmp
      self.pos = _save
      break
    end # end choice

    set_failed_rule :_array unless _tmp
    return _tmp
  end

  # array-body = value:x (- "," - value)*:xs { [x].concat(xs) }
  def _array_hyphen_body

    _save = self.pos
    while true # sequence
      _tmp = apply(:_value)
      x = @result
      unless _tmp
        self.pos = _save
        break
      end
      _ary = []
      while true

        _save2 = self.pos
        while true # sequence
          _tmp = apply(:__hyphen_)
          unless _tmp
            self.pos = _save2
            break
          end
          _tmp = match_string(",")
          unless _tmp
            self.pos = _save2
            break
          end
          _tmp = apply(:__hyphen_)
          unless _tmp
            self.pos = _save2
            break
          end
          _tmp = apply(:_value)
          unless _tmp
            self.pos = _save2
          end
          break
        end # end sequence

        _ary << @result if _tmp
        break unless _tmp
      end
      _tmp = true
      @result = _ary
      xs = @result
      unless _tmp
        self.pos = _save
        break
      end
      @result = begin;  [x].concat(xs) ; end
      _tmp = true
      unless _tmp
        self.pos = _save
      end
      break
    end # end sequence

    set_failed_rule :_array_hyphen_body unless _tmp
    return _tmp
  end

  # string = "\"" < string-char+ > "\"" { process_escapes(text) }
  def _string

    _save = self.pos
    while true # sequence
      _tmp = match_string("\"")
      unless _tmp
        self.pos = _save
        break
      end
      _text_start = self.pos
      _save1 = self.pos
      _tmp = apply(:_string_hyphen_char)
      if _tmp
        while true
          _tmp = apply(:_string_hyphen_char)
          break unless _tmp
        end
        _tmp = true
      else
        self.pos = _save1
      end
      if _tmp
        text = get_text(_text_start)
      end
      unless _tmp
        self.pos = _save
        break
      end
      _tmp = match_string("\"")
      unless _tmp
        self.pos = _save
        break
      end
      @result = begin;  process_escapes(text) ; end
      _tmp = true
      unless _tmp
        self.pos = _save
      end
      break
    end # end sequence

    set_failed_rule :_string unless _tmp
    return _tmp
  end

  # string-char = (!/["\\]/ . | "\\" string-char-escape)
  def _string_hyphen_char

    _save = self.pos
    while true # choice

      _save1 = self.pos
      while true # sequence
        _save2 = self.pos
        _tmp = scan(/\A(?-mix:["\\])/)
        _tmp = _tmp ? nil : true
        self.pos = _save2
        unless _tmp
          self.pos = _save1
          break
        end
        _tmp = get_byte
        unless _tmp
          self.pos = _save1
        end
        break
      end # end sequence

      break if _tmp
      self.pos = _save

      _save3 = self.pos
      while true # sequence
        _tmp = match_string("\\")
        unless _tmp
          self.pos = _save3
          break
        end
        _tmp = apply(:_string_hyphen_char_hyphen_escape)
        unless _tmp
          self.pos = _save3
        end
        break
      end # end sequence

      break if _tmp
      self.pos = _save
      break
    end # end choice

    set_failed_rule :_string_hyphen_char unless _tmp
    return _tmp
  end

  # string-char-escape = (/[\/\"bfnrt]/ | "u" /\d{4}/)
  def _string_hyphen_char_hyphen_escape

    _save = self.pos
    while true # choice
      _tmp = scan(/\A(?-mix:[\/\"bfnrt])/)
      break if _tmp
      self.pos = _save

      _save1 = self.pos
      while true # sequence
        _tmp = match_string("u")
        unless _tmp
          self.pos = _save1
          break
        end
        _tmp = scan(/\A(?-mix:\d{4})/)
        unless _tmp
          self.pos = _save1
        end
        break
      end # end sequence

      break if _tmp
      self.pos = _save
      break
    end # end choice

    set_failed_rule :_string_hyphen_char_hyphen_escape unless _tmp
    return _tmp
  end

  # number = (number-base:b number-exponent:e { b * (10 ** e) } | number-base:b { b })
  def _number

    _save = self.pos
    while true # choice

      _save1 = self.pos
      while true # sequence
        _tmp = apply(:_number_hyphen_base)
        b = @result
        unless _tmp
          self.pos = _save1
          break
        end
        _tmp = apply(:_number_hyphen_exponent)
        e = @result
        unless _tmp
          self.pos = _save1
          break
        end
        @result = begin;  b * (10 ** e) ; end
        _tmp = true
        unless _tmp
          self.pos = _save1
        end
        break
      end # end sequence

      break if _tmp
      self.pos = _save

      _save2 = self.pos
      while true # sequence
        _tmp = apply(:_number_hyphen_base)
        b = @result
        unless _tmp
          self.pos = _save2
          break
        end
        @result = begin;  b ; end
        _tmp = true
        unless _tmp
          self.pos = _save2
        end
        break
      end # end sequence

      break if _tmp
      self.pos = _save
      break
    end # end choice

    set_failed_rule :_number unless _tmp
    return _tmp
  end

  # number-base = (< number-base-whole number-base-frac > { text.to_f } | < number-base-whole > { text.to_i })
  def _number_hyphen_base

    _save = self.pos
    while true # choice

      _save1 = self.pos
      while true # sequence
        _text_start = self.pos

        _save2 = self.pos
        while true # sequence
          _tmp = apply(:_number_hyphen_base_hyphen_whole)
          unless _tmp
            self.pos = _save2
            break
          end
          _tmp = apply(:_number_hyphen_base_hyphen_frac)
          unless _tmp
            self.pos = _save2
          end
          break
        end # end sequence

        if _tmp
          text = get_text(_text_start)
        end
        unless _tmp
          self.pos = _save1
          break
        end
        @result = begin;  text.to_f ; end
        _tmp = true
        unless _tmp
          self.pos = _save1
        end
        break
      end # end sequence

      break if _tmp
      self.pos = _save

      _save3 = self.pos
      while true # sequence
        _text_start = self.pos
        _tmp = apply(:_number_hyphen_base_hyphen_whole)
        if _tmp
          text = get_text(_text_start)
        end
        unless _tmp
          self.pos = _save3
          break
        end
        @result = begin;  text.to_i ; end
        _tmp = true
        unless _tmp
          self.pos = _save3
        end
        break
      end # end sequence

      break if _tmp
      self.pos = _save
      break
    end # end choice

    set_failed_rule :_number_hyphen_base unless _tmp
    return _tmp
  end

  # number-base-whole = ("0" | /-?[1-9]\d*/)
  def _number_hyphen_base_hyphen_whole

    _save = self.pos
    while true # choice
      _tmp = match_string("0")
      break if _tmp
      self.pos = _save
      _tmp = scan(/\A(?-mix:-?[1-9]\d*)/)
      break if _tmp
      self.pos = _save
      break
    end # end choice

    set_failed_rule :_number_hyphen_base_hyphen_whole unless _tmp
    return _tmp
  end

  # number-base-frac = /\.\d+/
  def _number_hyphen_base_hyphen_frac
    _tmp = scan(/\A(?-mix:\.\d+)/)
    set_failed_rule :_number_hyphen_base_hyphen_frac unless _tmp
    return _tmp
  end

  # number-exponent = ("E" | "e") < /[+-]?\d+/ > { text.to_i }
  def _number_hyphen_exponent

    _save = self.pos
    while true # sequence

      _save1 = self.pos
      while true # choice
        _tmp = match_string("E")
        break if _tmp
        self.pos = _save1
        _tmp = match_string("e")
        break if _tmp
        self.pos = _save1
        break
      end # end choice

      unless _tmp
        self.pos = _save
        break
      end
      _text_start = self.pos
      _tmp = scan(/\A(?-mix:[+-]?\d+)/)
      if _tmp
        text = get_text(_text_start)
      end
      unless _tmp
        self.pos = _save
        break
      end
      @result = begin;  text.to_i ; end
      _tmp = true
      unless _tmp
        self.pos = _save
      end
      break
    end # end sequence

    set_failed_rule :_number_hyphen_exponent unless _tmp
    return _tmp
  end

  # - = /[ \t]*/
  def __hyphen_
    _tmp = scan(/\A(?-mix:[ \t]*)/)
    set_failed_rule :__hyphen_ unless _tmp
    return _tmp
  end

  # eof = !.
  def _eof
    _save = self.pos
    _tmp = get_byte
    _tmp = _tmp ? nil : true
    self.pos = _save
    set_failed_rule :_eof unless _tmp
    return _tmp
  end

  # strict-root = (object | array)
  def _strict_hyphen_root

    _save = self.pos
    while true # choice
      _tmp = apply(:_object)
      break if _tmp
      self.pos = _save
      _tmp = apply(:_array)
      break if _tmp
      self.pos = _save
      break
    end # end choice

    set_failed_rule :_strict_hyphen_root unless _tmp
    return _tmp
  end

  # root = (&{self.strict} strict-root:v | !{self.strict} value:v) eof { @result = v }
  def _root

    _save = self.pos
    while true # sequence

      _save1 = self.pos
      while true # choice

        _save2 = self.pos
        while true # sequence
          _save3 = self.pos
          _tmp = begin; self.strict; end
          self.pos = _save3
          unless _tmp
            self.pos = _save2
            break
          end
          _tmp = apply(:_strict_hyphen_root)
          v = @result
          unless _tmp
            self.pos = _save2
          end
          break
        end # end sequence

        break if _tmp
        self.pos = _save1

        _save4 = self.pos
        while true # sequence
          _save5 = self.pos
          _tmp = begin; self.strict; end
          _tmp = _tmp ? nil : true
          self.pos = _save5
          unless _tmp
            self.pos = _save4
            break
          end
          _tmp = apply(:_value)
          v = @result
          unless _tmp
            self.pos = _save4
          end
          break
        end # end sequence

        break if _tmp
        self.pos = _save1
        break
      end # end choice

      unless _tmp
        self.pos = _save
        break
      end
      _tmp = apply(:_eof)
      unless _tmp
        self.pos = _save
        break
      end
      @result = begin;  @result = v ; end
      _tmp = true
      unless _tmp
        self.pos = _save
      end
      break
    end # end sequence

    set_failed_rule :_root unless _tmp
    return _tmp
  end

  Rules = {}
  Rules[:_value] = rule_info("value", "(object | array | string | number | \"true\" { true } | \"false\" { false } | \"null\" { nil })")
  Rules[:_object] = rule_info("object", "(\"{\" - \"}\" { {} } | \"{\" - object-body:obj - \"}\" { obj })")
  Rules[:_object_hyphen_body] = rule_info("object-body", "object-pair:x (- \",\" - object-pair)*:xs { Hash[[x].concat(xs)] }")
  Rules[:_object_hyphen_pair] = rule_info("object-pair", "string:k - \":\" - value:v { [k, v] }")
  Rules[:_array] = rule_info("array", "(\"[\" - \"]\" { [] } | \"[\" - array-body:arr - \"]\" { arr })")
  Rules[:_array_hyphen_body] = rule_info("array-body", "value:x (- \",\" - value)*:xs { [x].concat(xs) }")
  Rules[:_string] = rule_info("string", "\"\\\"\" < string-char+ > \"\\\"\" { process_escapes(text) }")
  Rules[:_string_hyphen_char] = rule_info("string-char", "(!/[\"\\\\]/ . | \"\\\\\" string-char-escape)")
  Rules[:_string_hyphen_char_hyphen_escape] = rule_info("string-char-escape", "(/[\\/\\\"bfnrt]/ | \"u\" /\\d{4}/)")
  Rules[:_number] = rule_info("number", "(number-base:b number-exponent:e { b * (10 ** e) } | number-base:b { b })")
  Rules[:_number_hyphen_base] = rule_info("number-base", "(< number-base-whole number-base-frac > { text.to_f } | < number-base-whole > { text.to_i })")
  Rules[:_number_hyphen_base_hyphen_whole] = rule_info("number-base-whole", "(\"0\" | /-?[1-9]\\d*/)")
  Rules[:_number_hyphen_base_hyphen_frac] = rule_info("number-base-frac", "/\\.\\d+/")
  Rules[:_number_hyphen_exponent] = rule_info("number-exponent", "(\"E\" | \"e\") < /[+-]?\\d+/ > { text.to_i }")
  Rules[:__hyphen_] = rule_info("-", "/[ \\t]*/")
  Rules[:_eof] = rule_info("eof", "!.")
  Rules[:_strict_hyphen_root] = rule_info("strict-root", "(object | array)")
  Rules[:_root] = rule_info("root", "(&{self.strict} strict-root:v | !{self.strict} value:v) eof { @result = v }")
end
