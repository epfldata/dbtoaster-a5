#!/usr/bin/env ruby
require "#{File.dirname($0)}/util.rb"
require 'getoptlong'

$dbt_path = "#{File.dirname(File.dirname(File.dirname($0)))}"
$dbt = "#{$dbt_path}/dbtoaster"

raise "DBToaster is not compiled" unless (File.exists? $dbt_path)

def results_file(path, delim = /,/)
  File.open(path).readlines.
    delete_if { |l| l.chomp == "" }.  
    map do |l|
      k = l.split(delim).map { |i| i.to_f }
      [k, k.pop];
    end.to_h
end

$queries = {
  "rst" => {
    :path => "test/sql/simple/rst.sql",
    :type => :singleton,
    :answer => 18753367048934.0
  },
  "vwap" => {
    :path => "test/sql/finance/vwap.sql",
    :type => :singleton,
    :answer => 28916017900.0
  },
  "pricespread" => {
    :path => "test/sql/finance/pricespread.sql",
    :type => :singleton,
    :answer => 76452380068302.0
  },
  "axfinder" => {
    :path => "test/sql/finance/axfinder.sql",
    :type => :onelevel,
    :answer => { 
      [0.0] =>  2446668.0,
      [1.0] =>  -648039.0,
      [2.0] => -5363809.0,
      [3.0] =>   864240.0,
      [4.0] =>  8384852.0,
      [5.0] =>  3288320.0,
      [6.0] => -2605617.0,
      [7.0] =>   243551.0,
      [8.0] =>  1565128.0,
      [9.0] =>   995180.0
    }
  },
  "tpch3" => {
    :path => "test/sql/tpch/query3.sql",
    :type => :onelevel,
    :answer => {
      [ 0.0, 19941212.0, 3430.0 ] => 4726.6775,
      [ 0.0, 19950217.0, 4423.0 ] => 3055.9365,
      [ 0.0, 19950123.0, 2883.0 ] => 36666.9612,
      [ 0.0, 19941124.0, 3492.0 ] => 43716.0724,
      [ 0.0, 19941126.0, 998.0  ] => 11785.5486,
      [ 0.0, 19950208.0, 1637.0 ] => 164224.9253,
      [ 0.0, 19941211.0, 5191.0 ] => 49378.3094,
      [ 0.0, 19941223.0, 742.0  ] => 43728.048
    }
  },
  "tpch5" => {
    :path => "test/sql/tpch/query5.sql",
    :type => :onelevel,
    :answer => {
      [  0.0 ] => 28366643.0299,
      [  1.0 ] => 30290494.7397,
      [  2.0 ] => 36264557.6322,
      [  3.0 ] => 32340731.7701,
      [  4.0 ] => 35544694.5274,
      [  5.0 ] => 29447094.8207,
      [  6.0 ] => 26667158.8531,
      [  7.0 ] =>  42265166.775,
      [  8.0 ] => 36272867.5184,
      [  9.0 ] => 39286503.8203,
      [ 10.0 ] => 35771030.7947,
      [ 11.0 ] => 36349295.3331,
      [ 12.0 ] => 35727093.6313,
      [ 13.0 ] =>  22096426.003,
      [ 14.0 ] => 26955523.7857,
      [ 15.0 ] => 32725068.8962,
      [ 16.0 ] => 26366356.1375,
      [ 17.0 ] => 31904733.9555,
      [ 18.0 ] => 44678593.9358,
      [ 19.0 ] => 27350345.8278,
      [ 20.0 ] =>  35827832.436,
      [ 21.0 ] =>  31834053.855,
      [ 22.0 ] => 36508031.0309,
      [ 23.0 ] => 28454682.1614,
      [ 24.0 ] => 26840654.3967
    }
  },
  "tpch11" => {
    :path => "test/sql/tpch/query11a.sql",
    :type => :onelevel,
    :answer => results_file("test/results/tpch/query11.csv")
  }
};

class GenericUnitTest
  def query=(q, qdat = $queries[q])
    @qname = q;
    @qtype = qdat[:type];
    @qpath = qdat[:path];
    @expected = qdat[:answer];
    @result = Hash.new;
  end
    
  def query
    File.open(@qpath).readlines.join("");
  end
  
  def correct?
    case @qtype
      when :singleton then @result == @expected
      when :onelevel then
        not (@expected.keys + @result.keys).uniq.find do |k|
          @expected[k] != @result[k]
        end
      else raise "Unknown query type '#{@qtype}'"
    end
  end
  
  def results
    case @qtype
      when :singleton then [["*", @expected, @result]]
      when :onelevel then      
        (@expected.keys + @result.keys).uniq.
          map { |k| [k.join("/"), @expected[k], @result[k]] }
      else raise "Unknown query type '#{@qtype}'"
    end
  end
end

class CppUnitTest < GenericUnitTest
  def run
    unless $skip_compile then
      compile_cmd = [
        $dbt, 
        "-l","cpp",
        "-o","#{$dbt_path}/bin/#{@qname}.cpp",
        "-c","#{$dbt_path}/bin/#{@qname}",
        @qpath
      ].join(" ");
      system(compile_cmd) or raise "Compilation Error";
    end
    IO.popen("#{$dbt_path}/bin/#{@qname} -q", "r") do |qin|
      output = qin.readlines.map { |l| l.chomp }.join("")
      if(/<QUERY_1_1[^>]*>(.*)<\/QUERY_1_1>/ =~ output) then
        output = $1;
        case @qtype
          when :singleton then @result = output.to_f
          when :onelevel then
            tok = Tokenizer.new(output, /<\/?[^>]+>|[^<]+/);
            @result = Hash.new;
            loop do
              tok.tokens_up_to("<item>");
              break if tok.last != "<item>";
              fields = Hash.new("");
              curr_field = nil;
              tok.tokens_up_to("</item>").each do |t|
                case t
                  when /<\/.*>/ then curr_field = nil;
                  when /<(.*)>/ then curr_field = $1;
                  else 
                    if curr_field then 
                      fields[curr_field] = fields[curr_field] + t 
                    end
                end
              end
              keys = fields.keys.clone;
              keys.delete("__av");
              @result[
                keys.
                  map { |k| k[3..-1].to_i }.
                  sort.
                  map { |k| fields["__a#{k}"].to_f }
              ] = fields["__av"].to_f unless fields["__av"].to_f == 0.0
            end
          else nil
        end
      else puts output; raise "Runtime Error"
      end;
    end
  end
  
  def to_s
    "C++ Code Generator"
  end
end

class InterpreterUnitTest < GenericUnitTest
  def run
    IO.popen("#{$dbt} -r #{@qpath} 2>&1", "r") do |qin|
      output = qin.readlines.join("")
      raise "Runtime Error" unless (/QUERY_1_1: (.*)$/ =~ output);
      output = $1
      case @qtype
        when :singleton then @result = output.to_f
        when :onelevel then
          tok = Tokenizer.new(
            output, 
            /->|\[|\]|;|[0-9]+\.?[0-9]*|<pat=[^>]*>/
          );
          tok.clear_whitespace;
          tree = TreeBuilder.new;
          while(tok.more?) do
            case tok.next
              when "[" then 
                tree.push;
              when "]" then
                if tok.next == "->" 
                  then tree.insert tok.next.to_f 
                end
                tree.pop;
              when /[0-9]+\.[0-9]*/ then
                tree.insert tok.last.to_f
            end
          end
          @result = 
            tree.to_a.pop.map { |row| row.map { |v| v.to_f } }.
            map { |k| v = k.pop; [k, v] }.
            delete_if { |k,v| v == 0 }.
            to_h
        else nil
      end
    end
  end

  def to_s
    "OcaML Interpreter"
  end
end

tests = [];
queries = nil;
$skip_compile = false;

GetoptLong.new(
  [ '-a', '--all',  GetoptLong::NO_ARGUMENT],
  [ '-t', '--test', GetoptLong::REQUIRED_ARGUMENT],
  [ '--skip-compile', GetoptLong::NO_ARGUMENT]
).each do |opt, arg|
  case opt
    when '-a', '--all' then queries = $queries.keys
    when '--skip-compile' then $skip_compile = true;
    when '-t', '--test' then 
      case arg
        when 'cpp'         then tests.push CppUnitTest
        when 'interpreter' then tests.push InterpreterUnitTest
      end
  end
end

tests.uniq!
tests = [CppUnitTest] if tests.empty?;

queries = ARGV if queries.nil?

queries.each do |tquery| 
  tests.each do |test_class|
    t = test_class.new
    print "Testing query '#{tquery}' on the #{t.to_s}: "; STDOUT.flush;
    t.query = tquery
    begin t.run
      rescue Exception => e
        puts "Failure: #{e}";
        exit -1;
    end
    if t.correct? then
      puts "Success."
    else
      puts "Failure: Result Mismatch"
      puts(([["Key", "Expected", "Result"], 
             ["", "", ""]] + t.results).tabulate);
      exit -1;
    end
  end
end


