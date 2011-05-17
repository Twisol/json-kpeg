A simple (but complete) JSON parser written using Evan Phoenix's [kpeg](https://github.com/evanphx/kpeg).

By default, json-kpeg will accept any valid JSON value as the root value. To enable strict parsing (array
or object only as root), set `parser.strict = true` before calling `#parse`.

## Example
    require "json-kpeg"
    
    parser = JsonKpeg::Parser.new("[1, 2, 3]")
    if parser.parse
      p parser.result
    else
      parser.show_error
    end
