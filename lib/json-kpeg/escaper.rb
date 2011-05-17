module JsonKpeg::StringEscaper
  def process_escapes (str)
    str.gsub! /\\(u\d{4}|\D)/m do
      seq = $1
      case seq
        when '/' then "\/"
        when 'b' then "\b"
        when 'f' then "\f"
        when 'n' then "\n"
        when 'r' then "\r"
        when 't' then "\t"
        when '"' then '"'
        when '\\' then '\\'
        when /u\d{4}/ then seq[1..-1].to_i.chr
        else seq
      end
    end
    
    str
  end
end
