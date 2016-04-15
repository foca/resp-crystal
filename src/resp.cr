# Copyright (c) 2016 Michel Martens
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in
# all copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
# THE SOFTWARE.
#
require "socket"
require "uri"

class Resp
  class ProtocolError < Exception
  end

  alias Reply = Nil | Int64 | String | Array(Reply)

  def self.encode(args : Enumerable)
    String.build do |str|
      str << sprintf("*%d\r\n", args.size)

      args.each do |arg|
        str << sprintf("$%d\r\n%s\r\n", arg.bytesize, arg)
      end

      str << "\r\n"
    end
  end

  def self.encode(*args)
    encode(args)
  end

  def self.new(uri_string : String)
    uri = URI.parse(uri_string)

    host = uri.host || "localhost"
    port = uri.port || 6379
    auth = uri.password

    new(host, port, auth)
  end

  def initialize(host, port, auth = nil)
    @buff = Array(String).new
    @sock = TCPSocket.new(host, port)

    if auth
      call("AUTH", auth as String)
    end
  end

  def finalize
    @sock.close
  end

  def send_command(arg)
    @sock << arg
  end

  def discard_eol
    @sock.skip(2)
  end

  def discard_eol(str)
    str.byte_slice(0, str.bytesize - 2)
  end

  def readnum
    readstr.to_i64
  end

  def readstr
    str = @sock.gets

    raise ProtocolError.new unless str

    discard_eol(str)
  end

  def read_reply
    case @sock.read_char

    # RESP status
    when '+' then readstr

    # RESP error
    when '-' then readstr

    # RESP integer
    when ':' then readnum

    # RESP string
    when '$'
      size = readnum

      if size == -1
        return nil
      elsif size == 0
        discard_eol
        return ""
      end

      string = String.new(size) do |str|
        @sock.read_fully(Slice.new(str, size))
        {size, 0}
      end

      discard_eol
      return string

    # RESP array
    when '*'
      size = readnum
      list = Array(Reply).new

      if size == -1
        return nil
      elsif size == 0
        discard_eol
        return list
      end

      size.times do
        list << read_reply
      end

      return list
    else
      raise ProtocolError.new
    end
  end

  def call(args : Enumerable)
    send_command(Resp.encode(args))
    read_reply
  end

  def call(*args)
    call(args)
  end

  def reset
    @buff.clear
  end

  def queue(args : Enumerable)
    @buff << Resp.encode(args)
  end

  def queue(*args)
    queue(args)
  end

  def commit
    @buff.each do |arg|
      send_command(arg)
    end

    list = Array(Reply).new

    @buff.size.times do
      list << read_reply
    end

    return list

  ensure
    reset
  end

  def quit
    call("QUIT")
  end
end
