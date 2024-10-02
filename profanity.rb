#!/usr/bin/env ruby
# encoding: US-ASCII


=begin

	ProfanityFE v0.4
	Copyright (C) 2013  Matthew Lowe

	This program is free software; you can redistribute it and/or modify
	it under the terms of the GNU General Public License as published by
	the Free Software Foundation; either version 2 of the License, or
	(at your option) any later version.

	This program is distributed in the hope that it will be useful,
	but WITHOUT ANY WARRANTY; without even the implied warranty of
	MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
	GNU General Public License for more details.

	You should have received a copy of the GNU General Public License along
	with this program; if not, write to the Free Software Foundation, Inc.,
	51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.

	matt@lichproject.org
  
            author: Tillmen
      contributors: Deysh
              game: Gemstone
              tags: frontend
           version: 1.0.0
           
  Version Control:
  Major_change.feature_addition.bugfix
  1.0.0 (2024-09-30)
    - refactor
  0.4.0 (2013) - Initial release
  

=end

$prof_version = "1.0.0"
require 'json'
require 'benchmark'
require 'thread'
require 'socket'
require 'rexml/document'
require 'curses'
require 'fileutils'
require 'ostruct'

include Curses

require_relative "./settings/settings.rb"
require_relative "./ext/string.rb"
require_relative "./util/opts.rb"
require_relative "./ui/countdown.rb"
require_relative "./ui/indicator.rb"
require_relative "./ui/progress.rb"
require_relative "./ui/text.rb"
require_relative "./ui/keys.rb"
require_relative "./plugin/autocomplete.rb"
require_relative "./hilite/hilite.rb"

module Profanity
  class << self
    attr_accessor :debug_log, :settings_filename, :server, :server_time_offset, :skip_server_time_offset,
                  :port, :host, :highlight
  end

	self.debug_log                = Settings.file("log/debug.log")
  self.settings_filename        = Settings.file(".profanity/settings_file.xml")
  self.server                   = nil
  self.server_time_offset       = 0
  self.skip_server_time_offset  = false
  self.port                     = (Opts.port.to_i || 8000)
  self.host                     = (Opts.host || "127.0.0.1")
  self.highlight                = Hilite.pointer()

  # internal
  @title  = nil
	@status = nil
	@char   = Opts.char.capitalize
	@state  = {}

  unless defined?(Profanity.settings_filename)
    raise Exception, <<~ERROR
      you pust pass --char=<character>
      ###{Opts.parse()}
    ERROR
  end

	def self.log_file
		return File.open(Profanity.debug_log, 'a') { |file| yield file } if block_given?
	end

	def self.fetch(key, _default = nil)
		@state.fetch(key, _default)
	end

	def self.put(**args)
		@state.merge!(args)
	end

	def self.set_terminal_title(title)
		return if @title.eql?(title) # noop
		@title = title
		system("printf \"\033]0;#{title}\007\"")
		Process.setproctitle(title)
	end

	def self.app_title(*parts)
		return if @status == parts.join("")
		@status = parts.join("")
		return set_terminal_title(@char) if @status.empty?
		set_terminal_title([@char, "[#{parts.reject(&:empty?).join(":")}]"].join(" ").gsub(">", ""))
	end

	def self.update_process_title()
		return if Opts["no-status"]
		app_title(Profanity.fetch(:prompt, ""), Profanity.fetch(:room, ""))
	end

	def self.log(str)
		log_file { |f| f.puts str }
	end

	def self.help_menu()
    puts Opts.port
		# puts <<~HELP

			# Profanity FrontEnd v#{$version}

			  # --port=<port>
				# --default-color-id=<id>
				# --default-background-color-id=<id>
				# --custom-colors=<on|off>
				# --settings-file=<filename>
				# --char=<character>
				# --no-status                            do not redraw the process title with status updates
		# HELP
		# exit
	end
end

module Input
  def self.command_window_put_ch(ch)
    if (Input.command_buffer_pos - Input.command_buffer_offset + 1) >= UI.command_window.maxx
      UI.command_window.setpos(0,0)
      UI.command_window.delch
      Input.command_buffer_offset += 1
      UI.command_window.setpos(0, Input.command_buffer_pos - Input.command_buffer_offset)
    end
    Input.command_buffer.insert(Input.command_buffer_pos, ch)
    Input.command_buffer_pos += 1
    UI.command_window.insch(ch)
    UI.command_window.setpos(0, Input.command_buffer_pos - Input.command_buffer_offset)
  end

  def self.get_links(line)
    # First, add presets around all links.  If this does nothing, bail.
    line.gsub!(/(<[ad](?: [^>]*)?>.*?<\/[ad]>)/, "<preset id='link'>\\1</preset>")

    # Strip any of our freshly-added presets that occur during monsterbold, because in SF, bolded links use the
    # bold formatting rather than a mix of the two and that ceases to be true if a preset is applied.
    line.gsub!(/<pushBold\s*\/>.*?<popBold\s*\/>/) do |s|
      s.gsub(/<preset id='link'>(.*?)<\/preset>/, "\\1")
    end

    # Do the above for regular bold text too, which SF supports.
    line.gsub!(/<b\s*>.*?<\/b\s*>/) do |s|
      s.gsub(/<preset id='link'>(.*?)<\/preset>/, "\\1")
    end

    # Recolor and speech use presets.  We use presets.  Links within a preset normally follow the preset color,
    # so we need to strip any links we add within a preset...
    #
    # For performance reasons, and since we're unlikely to have 32 nested presets unless a script is misbehaving...
    # We cheat and use an int as a stack of booleans
    stack = 0
    line.gsub!(/<\/?preset([^>]*)>/) do |tag|
      if tag[1] == 'p' then    # Opening tag
        stack <<= 1  # Push next bits.
        if stack == 0 or $1 != " id='link'"
          # Stack is empty, or it wasn't a link.
          stack |= 1
          next tag
        else
          next ''
        end
      elsif stack == 0 then    # Stack underflow.  Silently ignore it.
        next tag
      elsif stack&1 == 1
        stack >>= 1
        next tag
      else
        stack >>= 1
        next ''
      end
    end

    return line
  end

  def self.add_prompt(window, cmd="")
    prompt_text = UI.prompt_text
    window.add_string("#{prompt_text}#{cmd}", [ h={ :start => 0, :end => (prompt_text.length + cmd.length), :fg => '555555', :bg => UI.main_bg} ])
  end

  def self.do_macro(macro)
      # fixme: gsub %whatever
      backslash = false
      at_pos = nil
      backfill = nil
      macro.split('').each_with_index { |ch, i|
        if backslash
          if ch == '\\'
            Input.command_window_put_ch('\\')
          elsif ch == 'x'
            Input.command_buffer.clear
            Input.command_buffer_pos = 0
            Input.command_buffer_offset = 0
            UI.command_window.deleteln
            UI.command_window.setpos(0,0)
          elsif ch == 'r'
            at_pos = nil
            Input.key_action['send_command'].call
          elsif ch == '@'
            Input.command_window_put_ch('@')
          elsif ch == '?'
            backfill = i - 3
          else
            nil
          end
          backslash = false
        else
          if ch == '\\'
            backslash = true
          elsif ch == '@'
            at_pos = Input.command_buffer_pos
          else
            Input.command_window_put_ch(ch)
          end
        end
      }
      if at_pos
        while at_pos < Input.command_buffer_pos
          Input.key_action['cursor_left'].call
        end
        while at_pos > Input.command_buffer_pos
          Input.key_action['cursor_right'].call
        end
      end
      UI.command_window.noutrefresh
      if backfill then
        UI.command_window.setpos(0,backfill)
        Input.command_buffer_pos = backfill
        backfill = nil
      end
      Curses.doupdate
    end

  def self.key_names
      {
        'ctrl+a'    => 1,
        'ctrl+b'    => 2,
      #	'ctrl+c'    => 3,
        'ctrl+d'    => 4,
        'ctrl+e'    => 5,
        'ctrl+f'    => 6,
        'ctrl+g'    => 7,
        'ctrl+h'    => 8,
        'win_backspace' => 8,
        'ctrl+i'    => 9,
        'tab'       => 9,
        'ctrl+j'    => 10,
        'enter'     => 10,
        'ctrl+k'    => 11,
        'ctrl+l'    => 12,
        'return'    => 13,
        'ctrl+m'    => 13,
        'ctrl+n'    => 14,
        'ctrl+o'    => 15,
        'ctrl+p'    => 16,
      #	'ctrl+q'    => 17,
        'ctrl+r'    => 18,
      #	'ctrl+s'    => 19,
        'ctrl+t'    => 20,
        'ctrl+u'    => 21,
        'ctrl+v'    => 22,
        'ctrl+w'    => 23,
        'ctrl+x'    => 24,
        'ctrl+y'    => 25,
        'ctrl+z'    => 26,
        'alt'       => 27,
        'escape'    => 27,
        # 'btn1'		=> 49,
        # '6'			=> 54,
        # '7'			=> 55,
        # 'ctrl+1'	=> 99,
        'ctrl+?'    => 127,
        'down'      => 258,
        'up'        => 259,
        'left'      => 260,
        'right'     => 261,
        'home'      => 262,
        'backspace' => 263,
        'f1'        => 265,
        'f2'        => 266,
        'f3'        => 267,
        'f4'        => 268,
        'f5'        => 269,
        'f6'        => 270,
        'f7'        => 271,
        'f8'        => 272,
        'f9'        => 273,
        'f10'       => 274,
        'f11'       => 275,
        'f12'       => 276,
        'delete'    => 330,
        'insert'    => 331,
        'page_down' => 338,
        'page_up'   => 339,
        'end'       => 360,
        'resize'    => 410,
        'num_7'         => 449,
        'num_8'         => 450,
        'num_9'         => 451,
        'num_4'         => 452,
        'num_5'         => 453,
        'num_6'         => 454,
        'num_1'         => 455,
        'num_2'         => 456,
        'num_3'         => 457,
        'num_enter'     => 459,
        'ctrl+delete' => 513,
        'alt+down'    => 517,
        'ctrl+down'   => 519,
        'keypad7'   => 534,
        'alt+left'    => 537,
        'ctrl+left'   => 539,
        'alt+page_down' => 542,
        'alt+page_up'   => 547,
        'alt+right'     => 552,
        'numpad_3'		=> 553,
        'ctrl+right'    => 554,
        'alt+up'        => 558,
        'ctrl+up'       => 560,
       'test' => 105
      }
    end

  def self.setup_key(xml, binding, key_action)
    if key = xml.attributes['id']
      if key =~ /^[0-9]+$/
        key = key.to_i
      elsif (key.class) == String and (key.length == 1)
        nil
      else
        key = Input.key_names[key]
      end
      if key
        if macro = xml.attributes['macro']
          binding[key] = proc { Input.do_macro(macro) }
        elsif xml.attributes['action'] and action = key_action[xml.attributes['action']]
          binding[key] = action
        else
          binding[key] ||= Hash.new
          xml.elements.each { |e|
            self.setup_key(e, binding[key], key_action)
          }
        end
      end
    end
  end

  def self.stow_macro(name)
    item = name.split(/\W/).last

    doc = REXML::Document.new
    doc.add_element('key')
    doc.root.add_attribute('id','alt')
    take = doc.root.add_element('key')
    take.add_attribute('id','t')
    take.add_attribute('macro',"\\xget my \\? from my #{item.downcase}")
    put = doc.root.add_element('key')
    put.add_attribute('id','p')
    put.add_attribute('macro',"\\xput my \\? in my #{item.downcase}")

    doc.elements.each { |e|
      if e.name == "key"
        Input.setup_key(e, Input.key_binding, Input.key_action)
      end
    }
    Input.first_time = false
  end

  def self.xml_escape_list
    {
      '&lt;'   => '<',
      '&gt;'   => '>',
      '&quot;' => '"',
      '&apos;' => "'",
      '&amp;'  => '&',
      #	'&#xA'   => "\n",
    }
  end
end

module UI
  def self.body_shapes(shape)
    body_shapes = {
      'other:poisoned' => 0x2718.chr('UTF-8'),
      'other:diseased' => 0x263C.chr('UTF-8'),
      'other:bleeding' => 0x2625.chr('UTF-8'),
    }

    return body_shapes[shape]
  end

  def self.process_room_sets
    # Define the sets
    room_sets = [UI.room_name, UI.room_desc, UI.also_see, UI.also_here, UI.compass]

    # Initialize the output hash
    output = {
      colors: [],
      text: ""
    }

    current_length = 0

    # Room set 1: Always has a line return
    if room_sets[0] && room_sets[0][:text]
      output[:text] << "#{room_sets[0][:text]}\n"
      text_length = room_sets[0][:text].length
      adjust_colors(room_sets[0][:colors], current_length, output[:colors], text_length)
      current_length += text_length
    end

    # Room sets 2 and 3: Combine and have a line return
    combined_text = ""
    combined_length = 0

    [1, 2].each do |i|
      if room_sets[i] && room_sets[i][:text]
        combined_text << room_sets[i][:text]
        text_length = room_sets[i][:text].length
        adjust_colors(room_sets[i][:colors], current_length + combined_length, output[:colors], text_length)
        combined_length += text_length
      end
    end
    unless combined_text.empty?
      output[:text] << "#{combined_text}\n"
      current_length += combined_length
    end

    # Room set 4: Has a line return
    if room_sets[3] && room_sets[3][:text]
      output[:text] << "#{room_sets[3][:text]}\n"
      text_length = room_sets[3][:text].length
      adjust_colors(room_sets[3][:colors], current_length, output[:colors], text_length)
      current_length += text_length
    end

    # Room set 5: Added at the end without a line return
    if room_sets[4] && room_sets[4][:text]
      output[:text] << "#{room_sets[4][:text]}"
      text_length = room_sets[4][:text].length
      adjust_colors(room_sets[4][:colors], current_length, output[:colors], text_length)
      current_length += text_length
    end

    # Return the final output hash
    output
  end

  def self.adjust_colors(colors, current_length, output_colors, text_length)
    return unless colors.is_a?(Array)  # Ensure colors is an array

    colors.each do |color|
      # Adjust the start and end positions based on the current length
      if color[:start].is_a?(Integer) && color[:end].is_a?(Integer)
        # Ensure the color does not exceed the text length
        if color[:start] < text_length
          adjusted_color = color.dup  # Duplicate color hash to avoid mutating original
          adjusted_color[:start] += current_length

          # Cap the end of the color if it exceeds the text length
          adjusted_color[:end] = [color[:end], text_length].min + current_length

          # Only push colors with valid start and end values
          if adjusted_color[:start] >= 0 && adjusted_color[:end] >= adjusted_color[:start]
            output_colors << adjusted_color
          end
        end
      end
    end
  end

  def self.compass_shapes(shape)
    shapes = {
      'compass:up' => 0x25B2.chr('UTF-8'),
      'compass:out' =>  0x2B22.chr("UTF-8"),
      'compass:down' => 0x25bc.chr('UTF-8'),
      'compass:nw' => 0x25E4.chr('UTF-8'),
      'compass:w'  => 0x25C4.chr('UTF-8'),
      'compass:sw' => 0x25E3.chr('UTF-8'),
      'compass:n' => 0x25B2.chr('UTF-8'),
      'compass:s' => 0x25BC.chr('UTF-8'),
      'compass:ne' => 0x25E5.chr('UTF-8'),
      'compass:e' => "\u25BA",
      'compass:se' => 0x25E2.chr('UTF-8'),

   #   'up' => 0x1F781.chr('UTF-8'),
      'out' =>  0x2B22.chr("UTF-8"),
      'down' => 0x1F783.chr('UTF-8'),
      'nw' => 0x25E4.chr('UTF-8'),
      'w'  => 0x25C4.chr('UTF-8'),
      'sw' => 0x25E3.chr('UTF-8'),
      'n' => 0x25B2.chr('UTF-8'),
      's' => 0x25BC.chr('UTF-8'),
      'ne' => 0x25E5.chr('UTF-8'),
      'e' => 0x25BA.chr('UTF-8'),
      'se' => 0x25E2.chr('UTF-8'),
    }

    return shapes[shape]
  end

  def self.fix_layout_number(str)
    # Replace 'lines' and 'cols' with actual terminal dimensions
    str = str.gsub('lines', Curses.lines.to_s).gsub('cols', Curses.cols.to_s)
    
    begin
      # Use Integer to safely convert the result of evaluating basic arithmetic
      Integer(eval(str))  # Safe eval assuming str contains simple arithmetic
    rescue SyntaxError, NameError, ArgumentError => e
      # Log the error and return 0 as a fallback
      $stderr.puts "Error evaluating layout string: #{e.message}"
      0
    end
  end

  def self.handle_game_text(text)
    Input.xml_escape_list.each_key do |escapable|
      search_pos = 0
      while (pos = text.index(escapable, search_pos))
        text.sub!(escapable, Input.xml_escape_list[escapable]) # In-place substitution

        # Adjust line color ranges
        UI.line_colors.each do |h|
          h[:start] -= (escapable.length - 1) if h[:start] > pos
          h[:end] -= (escapable.length - 1) if h[:end] > pos
        end

        # Adjust open style, if necessary
        if UI.open_style && (UI.open_style[:start] > pos)
          UI.open_style[:start] -= (escapable.length - 1)
        end
      end
    end

    if text =~ /^\[.*?\]>/
      UI.need_prompt = false
    elsif text =~ /^\s*You are stunned for ([0-9]+) rounds?/
      UI.new_stun($1.to_i * 5)
    elsif text =~ /^Deep and resonating, you feel the chant that falls from your lips instill within you with the strength of your faith\.  You crouch beside [A-Z][a-z]+ and gently lift (?:he|she|him|her) into your arms, your muscles swelling with the power of your deity, and cradle (?:him|her) close to your chest\.  Strength and life momentarily seep from your limbs, causing them to feel laden and heavy, and you are overcome with a sudden weakness\.  With a sigh, you are able to lay [A-Z][a-z]+ back down\.$|^Moisture beads upon your skin and you feel your eyes cloud over with the darkness of a rising storm\.  Power builds upon the air and when you utter the last syllable of your spell thunder rumbles from your lips\.  The sound ripples upon the air, and colling with [A-Z][a-z&apos;]+ prone form and a brilliant flash transfers the spiritual energy between you\.$|^Lifting your finger, you begin to chant and draw a series of conjoined circles in the air\.  Each circle turns to mist and takes on a different hue - white, blue, black, red, and green\.  As the last ring is completed, you spread your fingers and gently allow your tips to touch each color before pushing the misty creation towards [A-Z][a-z]+\.  A shock of energy courses through your body as the mist seeps into [A-Z][a-z&apos;]+ chest and life is slowly returned to (?:his|her) body\.$|^Crouching beside the prone form of [A-Z][a-z]+, you softly issue the last syllable of your chant\.  Breathing deeply, you take in the scents around you and let the feel of your surroundings infuse you\.  With only your gaze, you track the area and recreate the circumstances of [A-Z][a-z&apos;]+ within your mind\.  Touching [A-Z][a-z]+, you follow the lines of the web that holds (?:his|her) soul in place and force it back into (?:his|her) body\.  Raw energy courses through you and you feel your sense of justice and vengeance filling [A-Z][a-z]+ with life\.$|^Murmuring softly, you call upon your connection with the Destroyer,? and feel your words twist into an alien, spidery chant\.  Dark shadows laced with crimson swirl before your eyes and at your forceful command sink into the chest of [A-Z][a-z]+\.  The transference of energy is swift and immediate as you bind [A-Z][a-z]+ back into (?:his|her) body\.$|^Rich and lively, the scent of wild flowers suddenly fills the air as you finish your chant, and you feel alive with the energy of spring\.  With renewal at your fingertips, you gently touch [A-Z][a-z]+ on the brow and revel in the sweet rush of energy that passes through you into (?:him|her|his)\.$|^Breathing slowly, you extend your senses towards the world around you and draw into you the very essence of nature\.  You shift your gaze towards [A-z][a-z]+ and carefully release the energy you&apos;ve drawn into yourself towards (?:him|her)\.  A rush of energy briefly flows between the two of you as you feel life slowly return to (?:him|her)\.$|^Your surroundings grow dim\.\.\.you lapse into a state of awareness only, unable to do anything\.\.\.$|^Murmuring softly, a mournful chant slips from your lips and you feel welts appear upon your wrists\.  Dipping them briefly, you smear the crimson liquid the leaks from these sudden wounds in a thin line down [A-Z][a-z&apos;]+ face\.  Tingling with each second that your skin touches (?:his|hers), you feel the transference of your raw energy pass into [A-Z][a-z]+ and momentarily reel with the pain of its release\.  Slowly, the wounds on your wrists heal, though a lingering throb remains\.$|^Emptying all breathe from your body, you slowly still yourself and close your eyes\.  You reach out with all of your senses and feel a film shift across your vision\.  Opening your eyes, you gaze through a white haze and find images of [A-Z][a-z]+ floating above his prone form\.  Acts of [A-Z][a-z]&apos;s? past, present, and future play out before your clouded vision\.  With conviction and faith, you pluck a future image of [A-Z][a-z]+ from the air and coax (?:he|she|his|her) back into (?:he|she|his|her) body\.  Slowly, the film slips from your eyes and images fade away\.$|^Thin at first, a fine layer of rime tickles your hands and fingertips\.  The hoarfrost smoothly glides between you and [A-Z][a-z]+, turning to a light powder as it traverses the space\.  The white substance clings to [A-Z][a-z]+&apos;s? eyelashes and cheeks for a moment before it becomes charged with spiritual power, then it slowly melts away\.$|^As you begin to chant,? you notice the scent of dry, dusty parchment and feel a cool mist cling to your skin somewhere near your feet\.  You sense the ethereal tendrils of the mist as they coil about your body and notice that the world turns to a yellowish hue as the mist settles about your head\.  Focusing on [A-Z][a-z]+, you feel the transfer of energy pass between you as you return (?:him|her) to life\.$|^Wrapped in an aura of chill, you close your eyes and softly begin to chant\.  As the cold air that surrounds you condenses you feel it slowly ripple outward in waves that turn the breath of those nearby into a fine mist\.  This mist swiftly moves to encompass you and you feel a pair of wings arc over your back\.  With the last words of your chant, you open your eyes and watch as foggy wings rise above you and gently brush against [A-Z][a-z]+\.  As they dissipate in a cold rush against [A-Z][a-z]+, you feel a surge of power spill forth from you and into (?:him|her)\.$|^As .*? begins to chant, your spirit is drawn closer to your body by the scent of dusty, dry parchment\.  Topaz tendrils coil about .*?, and you feel an ancient presence demand that you return to your body\.  All at once .*? focuses upon you and you feel a surge of energy bind you back into your now-living body\.$/
      # raise dead stun
      UI.new_stun(30.6)
    elsif text =~ /^Just as you think the falling will never end, you crash through an ethereal barrier which bursts into a dazzling kaleidoscope of color!  Your sensation of falling turns to dizziness and you feel unusually heavy for a moment\.  Everything seems to stop for a prolonged second and then WHUMP!!!/
      # Shadow Valley exit stun
      UI.new_stun(16.2)
    elsif text =~ /^You have.*?(?:case of uncontrollable convulsions|case of sporadic convulsions|strange case of muscle twitching)/
      # nsys wound will be correctly set by xml, dont set the scar using health verb output
      skip_nsys = true
    else
      if skip_nsys
        skip_nsys = false
      elsif window = UI.indicator_handler['nsys']
        if text =~ /^You have.*? very difficult time with muscle control/
          if window.update(3)
            UI.need_update = true
          end
        elsif text =~ /^You have.*? constant muscle spasms/
          if window.update(2)
            UI.need_update = true
          end
        elsif text =~ /^You have.*? developed slurred speech/
          if window.update(1)
            UI.need_update = true
          end
        end
      end
    end

    if UI.open_style
      h = UI.open_style.dup
      h[:end] = text.length
      UI.line_colors.push(h)
      UI.open_style[:start] = 0
    end

    UI.open_color.each do |oc|
      UI.line_colors << oc.merge(end: text.length, start: 0)
    end

    if UI.current_stream.nil? or UI.stream_handler[UI.current_stream] or (UI.current_stream =~ /^(?:death|logons|thoughts|voln|familiar|room objs|room players|bounty|roomName|roomDesc)$/)
      UI.settings_lock.synchronize do
        Profanity.highlight.each_pair do |regex,colors|
          pos = 0
          while (match_data = text.match(regex, pos))
            h = {
              :start => match_data.begin(0),
              :end => match_data.end(0),
              :fg => colors[0],
              :bg => colors[1],
              :ul => colors[2]
            }
            UI.line_colors.push(h)
            pos = match_data.end(0)
          end
        end
      end
    end

    unless text.empty?
      if UI.current_stream
        if UI.current_stream == 'thoughts'
          if text =~ /^\[.+?\]\-[A-z]+\:[A-Z][a-z]+\: "|^\[server\]\: /
            UI.current_stream = 'lnet'
          end
        end

        if window = UI.stream_handler[UI.current_stream]
          if UI.current_stream == 'death'
            # fixme: has been vaporized!
            # fixme: ~ off to a rough start
            if text =~ /^\s\*\s(The death cry of )?([A-Z][a-z]+) (?:just bit the dust!|echoes in your mind!)/
              front_count = 3
              front_count += 17 if $1
              name = $2
              text = "#{name} #{Time.now.strftime('%l:%M%P').sub(/^0/, '')}"
              UI.line_colors.each { |h|
                h[:start] -= front_count
                h[:end] = [ h[:end], name.length ].min
              }
              UI.line_colors.delete_if { |h| h[:start] >= h[:end] }
              h = {
                :start => (name.length+1),
                :end => text.length,
                :fg => 'ff0000',
              }
              UI.line_colors.push(h)
            end
          elsif UI.current_stream == 'logons'
            foo = { 'joins the adventure.' => '007700', 'returns home from a hard day of adventuring.' => '777700', 'has disconnected.' => 'aa7733' }
            if text =~ /^\s\*\s([A-Z][a-z]+) (#{foo.keys.join('|')})/
              name = $1
              logon_type = $2
              text = "#{name} #{Time.now.strftime('%l:%M%P').sub(/^0/, '')}"
              UI.line_colors.each { |h|
                h[:start] -= 3
                h[:end] = [ h[:end], name.length ].min
              }
              UI.line_colors.delete_if { |h| h[:start] >= h[:end] }
              h = {
                :start => (name.length+1),
                :end => text.length,
                :fg => foo[logon_type],
              }
              UI.line_colors.push(h)
            end
          end
          unless text =~ /^\[server\]: "(?:kill|connect)/
            window.add_string(text, UI.line_colors)
            UI.need_update = true
          end
        elsif UI.current_stream =~ /^(?:death|logons|thoughts|voln|familiar)$/
          if window = UI.stream_handler['main']
            if UI.preset[UI.current_stream]
              UI.line_colors.push(:start => 0, :fg => UI.preset[UI.current_stream][0], :bg => UI.preset[UI.current_stream][1], :end => text.length)
            end
            unless text.empty?
              if UI.need_prompt
                UI.need_prompt = false
                Input.add_prompt(window, "")
              end
              window.add_string(text, UI.line_colors)

              UI.need_update = true
            end
          end
        elsif UI.current_stream == 'room objs' && text =~ /You also see/
          see_text = Marshal.load(Marshal.dump(text))
          see_color = Marshal.load(Marshal.dump(UI.line_colors))

          UI.also_see[:text] = see_text
          UI.also_see[:colors] = see_color
          UI.also_see[:index] = 2
        elsif UI.current_stream == "room players"
          here_text = Marshal.load(Marshal.dump(text))
          here_color = Marshal.load(Marshal.dump(UI.line_colors))

          UI.also_here[:text] = here_text
          UI.also_here[:colors] = here_color
          UI.also_here[:index] = 3
        elsif UI.current_stream == "room exits"
          exit_text = Marshal.load(Marshal.dump(text))
          exit_color = Marshal.load(Marshal.dump(UI.line_colors))

          UI.compass[:text] = exit_text
          UI.compass[:colors] = exit_color
          UI.compass[:index] = 4
        elsif UI.current_stream == "roomName"
          title_text = Marshal.load(Marshal.dump(text))
          title_color = Marshal.load(Marshal.dump(UI.line_colors))

          UI.room_name[:text] = title_text
          UI.room_name[:colors] = title_color
          UI.room_name[:index] = 0
        end
      else
        room_text = Marshal.load(Marshal.dump(text))
        room_color = Marshal.load(Marshal.dump(UI.line_colors))

        if window = UI.stream_handler['main']
          if UI.need_prompt
            UI.need_prompt = false
            Input.add_prompt(window, "")
          end
          UI.line_colors.each { |k,v| k[:bg] = UI.main_bg}
          window.add_string(text, UI.line_colors)
          UI.need_update = true
        end

        if UI.is_room
          UI.is_room = false

          UI.room_desc[:text] = Marshal.load(Marshal.dump(room_text)).split("You also")[0]
          UI.room_desc[:colors] = Marshal.load(Marshal.dump(room_color))
          UI.room_desc[:index] = 1
        end

        # coordinates the various room texts
        room_sets = UI.process_room_sets
        if (room_sets.to_s.length != UI.old_set.to_s.length) #&& !UI.new_room
          UI.old_set = Marshal.load(Marshal.dump(room_sets))

          UI.stream_handler['room'].clear_window
          UI.stream_handler['room'].refresh

          UI.stream_handler['room'].setpos(0, 0)
          UI.stream_handler['room'].add_string(room_sets[:text], room_sets[:colors])
        end
      end
    end
    UI.line_colors = []
  end

  def self.load_layout(layout_id)
    if xml = UI.layout[layout_id]
      old_windows = IndicatorWindow.list | TextWindow.list | CountdownWindow.list | ProgressWindow.list

      previous_indicator_handler = UI.indicator_handler
      UI.indicator_handler = Hash.new

      previous_stream_handler = UI.stream_handler
      UI.stream_handler = Hash.new

      previous_progress_handler = UI.progress_handler
      UI.progress_handler = Hash.new

      previous_countdown_handler = UI.countdown_handler
      UI.countdown_handler = Hash.new

      xml.elements.each do |e|
        if e.name == 'main_colors'
          UI.main_fg = e.attributes['fg'] ? e.attributes['fg'] : UI::Window.get_default
          UI.main_bg = e.attributes['bg'] ? e.attributes['bg'] : UI::Window.get_default_background
        end

        if e.name == 'window'
          # grabs the dimensions from the layout
          height, width, top, left = %w[height width top left].map { |attr| UI.fix_layout_number(e.attributes[attr]) }

          if (height > 0) and (width > 0) and (top >= 0) and (left >= 0) and (top < Curses.lines) and (left < Curses.cols)
            if e.attributes['class'] == 'indicator'
              if e.attributes['value'] && (window = previous_indicator_handler.delete(e.attributes['value']))
                old_windows.delete(window)
              else
                window = IndicatorWindow.new(height, width, top, left)
              end

              # Set layout and scroll
              window.layout = %w[height width top left].map { |attr| e.attributes[attr] }
              window.scrollok(false)

              # Set label based on 'value'
              case e.attributes['value']
              when /compass/
                window.label = UI.compass_shapes(e.attributes['value']) || e.attributes['label']
              when /other/
                window.label = UI.body_shapes(e.attributes['value'])
              when /injury/
                window.label = e.attributes['label']
              else
                window.label = e.attributes['label'] if e.attributes['label']
              end

              # Handle colors
              if e.attributes['fg']
                window.fg = e.attributes['fg'].split(',').map { |val| val == 'nil' ? nil : val }
              end

              if e.attributes['bg']
                window.bg = e.attributes['bg'].split(',').map { |val| val == 'nil' ? nil : val }
              end

              # Assign window to the indicator handler
              if e.attributes['value']
                e.attributes['value'].split(',').each do |str|
                  UI.indicator_handler[str] = window
                end
              end

              window.redraw
            elsif e.attributes['class'] == 'text'
              if width > 1
                stream_value = e.attributes['value']
                existing_window = stream_value && previous_stream_handler.find { |key, _| stream_value.split(',').include?(key) }&.last

                if existing_window
                  previous_stream_handler[stream_value] = nil
                  old_windows.delete(existing_window)
                else
                  window = TextWindow.new(height, width - 1, top, left)
                  window.scrollbar = Curses::Window.new(window.maxy, 1, window.begy, window.begx + window.maxx)
                end

                # Set window properties
                window.layout = [e.attributes['height'], e.attributes['width'], e.attributes['top'], e.attributes['left']]
                window.scrollok(true)
                window.max_buffer_size = e.attributes['buffer-size'] || 1000

                # Update stream handler
                stream_value.split(',').each { |str| UI.stream_handler[str] = window }

                # Set background if value is "main"
                window.bkgd(Curses::color_pair(UI::Window.get_color_pair_id(UI.main_fg, UI.main_bg))) if stream_value == "main"
              end
            elsif e.attributes['class'] == 'countdown'
              if e.attributes['value'] and (window = previous_countdown_handler[e.attributes['value']])
                previous_countdown_handler[e.attributes['value']] = nil
                old_windows.delete(window)
              else
                window = CountdownWindow.new(height, width, top, left)
              end
              window.layout = [ e.attributes['height'], e.attributes['width'], e.attributes['top'], e.attributes['left'] ]
              window.scrollok(false)
              window.width = e.attributes['width'] if e.attributes['width']
              window.label = e.attributes['label'] if e.attributes['label']
              window.fg = e.attributes['fg'].split(',').collect { |val| if val == 'nil'; nil; else; val; end  } if e.attributes['fg']
              window.bg = e.attributes['bg'].split(',').collect { |val| if val == 'nil'; nil; else; val; end  } if e.attributes['bg']
              if e.attributes['value']
                UI.countdown_handler[e.attributes['value']] = window
              end
              if e.attributes['value'] != "bar_time"
                window.update_number
              else
                window.update
              end
            elsif e.attributes['class'] == 'progress'
              progress_value = e.attributes['value']

              if progress_value && (window = previous_progress_handler[progress_value])
                previous_progress_handler[progress_value] = nil
                old_windows.delete(window)
              else
                window = ProgressWindow.new(height, width, top, left)
              end

              # Set window properties
              window.layout = [e.attributes['height'], e.attributes['width'], e.attributes['top'], e.attributes['left']]
              window.scrollok(false)

              # Assign label if present
              window.label = e.attributes['label'] if e.attributes['label']

              # Set foreground color if present
              if e.attributes['fg']
                window.fg = e.attributes['fg'].split(',').map { |val| val == 'nil' ? nil : val }
              end

              # Set background color if present
              if e.attributes['bg']
                window.bg = e.attributes['bg'].split(',').map { |val| val == 'nil' ? nil : val }
              end

              # Update progress handler
              if progress_value
                UI.progress_handler[progress_value] = window
              end

              # Redraw the window
              window.redraw
            elsif e.attributes['class'] == 'command'
              unless UI.command_window
                UI.command_window = Curses::Window.new(height, width, top, left)
              end
              UI.command_window_layout = [ e.attributes['height'], e.attributes['width'], e.attributes['top'], e.attributes['left'] ]
              UI.command_window.scrollok(false)
              UI.command_window.keypad(true)
            end
          end
        end
      end

      if current_scroll_window = TextWindow.list[0]
        current_scroll_window.update_scrollbar
      end

      if current_scroll_window = TextWindow.list[1]
        current_scroll_window.update_scrollbar
      end

      old_windows.each do |window|
        [IndicatorWindow.list, TextWindow.list, CountdownWindow.list, ProgressWindow.list].each do |list|
          list.delete(window)
        end

        window.scrollbar.close if window.is_a?(TextWindow)
        window.close
      end
      
      Curses.doupdate
    end
  end

  def self.load_settings_file(reload)
    UI.settings_lock.synchronize do
      begin
        xml = Hilite.load(file: Profanity.settings_filename, flush: reload)
        unless reload
          xml.elements.each do |e|
            # These are things that we ignore if we're doing a reload of the settings file
            if e.name == 'preset'
              UI.preset[e.attributes['id']] = [ e.attributes['fg'], e.attributes['bg'] ]
            elsif (e.name == 'layout') and (layout_id = e.attributes['id'])
              UI.layout[layout_id] = e
            elsif e.name == 'key'
              Input.setup_key(e, Input.key_binding, Input.key_action)
            end
          end
        end
      rescue
        Profanity.log $!
        Profanity.log $!.backtrace[0..1]
      end
    end
  end

  def self.new_stun(seconds)
    if (window = UI.countdown_handler['stunned'])
      temp_stun_end = Time.now.to_f - Profanity.server_time_offset.to_f + seconds.to_f
      window.end_time = temp_stun_end
      window.update
      UI.need_update = true

      # Create a new thread to update the stun countdown periodically
      Thread.new do
        while window.end_time == temp_stun_end && window.value > 0
          sleep 0.15
          if window.update
            UI.command_window.noutrefresh
            Curses.doupdate
          end
        end
      end
    end
  end

  class SpellWindow
    def self.spell_colors
      {
        100   => "600000",  # Minor Spirit
        200   => "2B0000",  # Major Spirit
        300   => "f5533d",  # Cleric
        400   => "3455DB",  # Minor Elemental
        500   => "0F4880",  # Major Elemental
        600   => "002A15",  # Ranger
        700   => "58007E",  # Sorcerer
        900   => "3E92CF",  # Wizard
        1000  => "108ebc",  # Bard
        1100  => "932906",  # Empath
        1200  => "975E31",  # Minor Mental
        1600  => "716891",  # Paladin
        1700  => "d08216",  # LFM
        6666  => 475,
        9000  => 515,
        9500  => "4B6A88",  # Armor
        9516  => 595,
        9600  => 635,
        9700  => 675,
        9725  => "093145",  # Next Bounty
        9800  => "6D8891",  # Voln
        9900  => "6D8891",  # CoL
      }
    end

    def self.spell_names
      {
        "Spirit Warding I"       => 100,
        "Spirit Barrier"         => 100,
        "Spirit Defense"         => 100,
        "Disease Resistance"     => 100,
        "Poison Resistance"      => 100,
        "Spirit Warding II"      => 100,
        "Water Walking"          => 100,
        "Fasthr's Reward"        => 100,
        "Lesser Shroud"          => 100,
        "Spirit Shield"          => 200,
        "Purify Air"             => 200,
        "Bravery"                => 200,
        "Heroism"                => 200,
        "Manna"                  => 200,
        "Spirit Servant"         => 200,
        "Spell Shield"           => 200,
        "Untrammel"              => 200,
        "Prayer of Protection"   => 300,
        "Benediction"            => 300,
        "Warding Sphere"         => 300,
        "Prayer"                 => 300,
        "Soul Ward"              => 300,
        "Ethereal Censer"        => 300,
        "Elemental Defense I"    => 400,
        "Elemental Defense II"   => 400,
        "Elemental Defense III"  => 400,
        "Elemental Targeting"    => 400,
        "Elemental Barrier"      => 400,
        "Lock Pick Enhancement"  => 400,
        "Disarm Enhancement"     => 400,
        "Presence"               => 400,
        "Thurfel's Ward"         => 500,
        "Strength"               => 500,
        "Elemental Deflection"   => 500,
        "Elemental Bias"         => 500,
        "Elemental Focus"        => 500,
        "Haste"                  => 500,
        "Mage Armor - Fire"      => 500,
        "Mage Armor - Water"     => 500,
        "Mage Armor - Air"       => 500,
        "Mage Armor - Earth"     => 500,
        "Mage Armor - Lightning" => 500,
        "Celerity"               => 500,
        "Temporal Reversion"     => 500,
        "Rapid Fire"             => 500,
        "Mana Leech"             => 500,
        "Natural Colors"         => 600,
        "Resist Elements"        => 600,
        "Nature's Bounty"        => 600,
        "Phoen's Strength"       => 600,
        "Self Control"           => 600,
        "Sneaking"               => 600,
        "Mobility"               => 600,
        "Nature's Touch"         => 600,
        "Wall of Thorns"         => 600,
        "Camouflage"             => 600,
        "Cloak of Shadows"       => 700,
        "Pestilence"             => 700,
        "Prismatic Guard"        => 900,
        "Mass Blur"              => 900,
        "Melgorehn's Aura"       => 900,
        "Tremors"                => 900,
        "Wizard's Shield"        => 900,
        "Song of Luck"           => 1000,
        "Fortitude Song"         => 1000,
        "Kai's Triumph Song"     => 1000,
        "Song of Valor"          => 1000,
        "Sonic Shield Song"      => 1000,
        "Sonic Weapon Song"      => 1000,
        "Sonic Armor"            => 1000,
        "Song of Mirrors"        => 1000,
        "Empathic Focus"         => 1100,
        "Strength Of Will"       => 1100,
        "Troll's Blood"          => 1100,
        "Intensity"              => 1100,
        "Foresight"              => 1200,
        "Mindward"               => 1200,
        "Mind over Body"         => 1200,
        "Premonition"            => 1200,
        "Blink"                  => 1200,
        "Mantle of Faith"        => 1600,
        "Arm of the Arkati"      => 1600,
        "Zealot"                 => 1600,
        "Focused"                => 1700,
        "Armor Support"          => 9500,
        "Armored Fluidity"       => 9500,
        "Stance of the Mongoose" => 9500,
        "Next Bounty"            => 9725,
        "Symbol of Protection"   => 9800,
        "Symbol of Courage"      => 9800,
        "Symbol of Supremacy"    => 9800,
        "Sign of Staunching"     => 9900,
        "Sign of Warding"        => 9900,
        "Sign of Striking"       => 9900,
        "Sign of Defending"      => 9900,
        "Sign of Smiting"        => 9900,
        "Sign of Deflection"     => 9900,
        "Sign of Swords"         => 9900,
        "Sign of Shields"        => 9900,
        "Sign of Dissipation"    => 9900,
        "Sigil of Defense"       => 9900,
        "Sigil of Offense"       => 9900,
        "Sigil of Concentration" => 9900,
        "Sigil of Major Bane"    => 9900,
      }
    end

    def self.spell_shade(color)
      spell_id = spell_names[color]
      spell_colors[spell_id] if spell_id && spell_colors[spell_id]
    end

    def self.spell_space(spell_list)
      spell_list.map! do |element|
        element[1] = " #{element[1]}"  # Add space to the second item
        element  # Return the modified sub-array
      end
    end

    def self.update_spells(line)
      stream_handler = UI.stream_handler

      @active_spells    ||= []
      @cooldown_spells  ||= []
      @buff_spells      ||= []
      @debuff_spells    ||= []

      if line =~ /^<dialogData id='(Active Spells|Buffs|Debuffs|Cooldowns)'/
        current_list = Regexp.last_match(1)
      end

      spell_colors = []

      # Extract spell details into a nested array
      spell_list = line.scan(/value='(.*?)' text="(.*?)".*?value='(.*?)'/).flatten.each_slice(3).to_a

      # Categorize spells based on the current list
      case current_list
      when "Active Spells"
        @active_spells = spell_list.empty? ? [['', ' No spells found.', '']] : self.spell_space(spell_list)
      when "Cooldowns"
        @cooldown_spells = spell_list.empty? ? [['', ' No cooldowns found.', '']] : self.spell_space(spell_list)
      when "Buffs"
        @buff_spells = spell_list.empty? ? [['', ' No buffs found.', '']] : self.spell_space(spell_list)
      when "Debuffs"
        @debuff_spells = spell_list.empty? ? [['', ' No debuffs found.', '']] : self.spell_space(spell_list)
      end

      # build the display
      @all_spells = []  # Reset the list first
      @all_spells += [['', 'Spells:', '']] + @active_spells
      @all_spells += [['', 'Cooldowns:', '']] + @cooldown_spells
      @all_spells += [['', 'Buffs:', '']] + @buff_spells
      @all_spells += [['', 'Debuffs:', '']] + @debuff_spells

       stream_handler['spell_container'].clear_window

      @all_spells.each{ |item|
        next if item[1] =~ /Nature's Touch Arcane Reflexes|Ensorcell/

        if item[1] =~ /Spells:|Cooldowns:|Buffs:|Debuffs:|No.*found./
          num_dots = 0
        else
          num_dots = [0, 32 - (item[1].length + item[2].length)].max
        end

        string_dots = '.' * num_dots
        spell_text =  ' ' + item[1] + string_dots + item[2]

        percent = item[0].to_i
        spell_bar = ((spell_text.length * percent) / 100).clamp(3, spell_text.length)

        h = {
          :start => 2,
          :end => spell_bar,
          :bg => self.spell_shade(item[1].strip),
        }
        spell_colors.push(h)

        stream_handler['spell_container'].add_string(spell_text, spell_colors)
      }

      stream_handler['spell_container'].resize(@all_spells.length + 2,39)
    end
  end

  class Window
    def self.init
      Curses.start_color
      Curses.assume_default_colors(-1,-1);

      self.set_colors
    end

    def self.set_colors
      @color_pair_id_lookup = {}
      @color_pair_history   = []
      @default_color_id            = (Opts.color_id            || 7).to_i
      @default_background_color_id = (Opts.background_color_id || 0).to_i
      @custom_colors ||= Curses.can_change_color?
      @default_color_code = Curses.color_content(@default_color_id).collect { |num| ((num/1000.0)*255).round.to_s(16) }.join('').rjust(6, '0')
      @default_background_color_code = Curses.color_content(@default_background_color_id).collect { |num| ((num/1000.0)*255).round.to_s(16) }.join('').rjust(6, '0')

      @color_id_lookup = Hash.new
      @color_id_lookup[@default_color_code] = @default_color_id
      @color_id_lookup[@default_background_color_code] = @default_background_color_id

      @color_code = {
        basic: ['000000', '800000', '008000', '808000', '000080', '800080', '008080', 'c0c0c0'],
        bright: ['ff0000', '00ff00', 'ffff00', '0000ff', 'ff00ff', '00ffff', 'ffffff'],
        dark: ['080808', '121212', '1c1c1c', '262626', '303030', '3a3a3a', '444444', '4e4e4e'],
        light: ['d0d0d0', 'dadada', 'e4e4e4', 'eeeeee'],
        extended: ['00005f', '000087', '0000af', '0000d7', '0000ff', '005f00', '005f5f', '005f87']
      }

      if @custom_colors
        @color_id_history = (0...Curses.colors).reject do |num|
          num == @default_color_id || num == @default_background_color_id
        end
      end

      (1..[Curses::color_pairs, 256].min - 1).each do |num|
        @color_pair_history.push(num)
      end
    end

    def self.get_color_id(code)
      return @color_id_lookup[code] if @color_id_lookup.key?(code)

      if @custom_colors
        color_id = @color_id_history.shift
        @color_id_lookup.delete_if { |_, v| v == color_id }

        Curses.init_color(
          color_id,
          *code.scan(/../).map { |component| ((component.hex / 255.0) * 1000).round }
        )

        @color_id_lookup[code] = color_id
        @color_id_history.push(color_id)
        return color_id
      else
        all_colors = @color_code.values.flatten

        # Find the color ID with the least error
        least_error_id = all_colors.each_with_index.min_by do |color, _|
          code.scan(/../).zip(color.scan(/../)).sum { |c, cc| (c.hex - cc.hex)**2 }
        end.last

        @color_id_lookup[code] = least_error_id
        return least_error_id
      end
    end

    def self.get_color_pair_id(fg_code, bg_code)
      fg_id = fg_code.nil? ? @default_color_id : self.get_color_id(fg_code)

      #bg_id = DEFAULT_BACKGROUND_COLOR_ID	Fixme
      bg_id = bg_code.nil? ? self.get_color_id('4a4a4a') : self.get_color_id(bg_code)

      if @color_pair_id_lookup[fg_id] && (color_pair_id = @color_pair_id_lookup[fg_id][bg_id])
        color_pair_id
      else
        color_pair_id = @color_pair_history.shift

        @color_pair_id_lookup.each do |_, pairs|
          pairs.delete_if { |_, id| id == color_pair_id }
        end
        sleep 0.01
        Curses.init_pair(color_pair_id, fg_id, bg_id)
        @color_pair_id_lookup[fg_id] ||= {}
        @color_pair_id_lookup[fg_id][bg_id] = color_pair_id
        @color_pair_history.push(color_pair_id)
        color_pair_id
      end
    end

    def self.get_default
      @default_color_id
    end

    def self.get_default_background
      @default_background_color_id
    end

    def self.custom_colors
      @custom_colors
    end

    def self.get_color_id_lookup
      @color_id_lookup
    end
  end
end

module Update
  def self.launch_browser(code) 
    url = "\"https://www.play.net#{code}\""
    wsl_url = url.gsub(/&/, "^&")

    if ENV["WSL_DISTRO_NAME"]
      # Windows Subsystem for Linux (WSL)
      system "cmd.exe /c start #{wsl_url}"
    else
      case RbConfig::CONFIG['host_os']
      when /mswin|mingw|cygwin/
        # Windows
        system "start #{url} >/dev/null 2>&1 &"
      when /darwin/
        # macOS
        system "open #{url} >/dev/null 2>&1 &"
      when /linux|bsd/
        # Linux or BSD
        system "xdg-open #{url} >/dev/null 2>&1 &"
      else
        # Unsupported OS
        puts "Unsupported OS: #{RbConfig::CONFIG['host_os']}"
      end
    end
  end
  
  def self.stow_container(line)
    if Input.first_time
      name = line.scan(/noun=".*?">(.*?)<\/a>.*?/).flatten.first
      Input.stow_macro(name) #creates a macro to take(alt+t) and put(alt+p) for your stow container
    end

    # lets find the stow container name
    stow_regex = /<a exist=".*" noun=".*">(.*?)<\/a>/
    stow_match = line.scan(stow_regex).last.flatten
    stow_name = stow_match.first.split(/ |\_/).map(&:capitalize).join(' ')


    # grab all the items
    matches = line.scan(/<inv id='stow'>.*?<a exist=".*?" noun=".*?">(.*?)<\/a>.*?<\/inv>/).flatten
    matches = matches[1..-1].sort_by(&:downcase) # Skip the first match and sort
    if matches.length > 26
      matches = matches.first(25)
      matches << "...and other stuff"
    end

    UI.stream_handler['item_container'].clear_window
    UI.stream_handler['item_container'].add_string "#{stow_name}: "

    matches.each do |item|
      item = item.split(/ |\_/).map(&:capitalize).join(" ")
      UI.stream_handler['item_container'].add_string "  #{item.gsub(/vial.*/i, 'vial')} "
    end
  end

  def self.inventory(lines)
    inv_size = 11
    inv = lines.scan(/noun=".*?">(.*?)<\/a>.*?/).flatten

    formatted_inv = inv.map { |str| str.split.length > 1 ? str.split[-2, 2].join(' ') : str }
                       .map { |item| item.gsub('some', '').strip.split(/ |\_/).map(&:capitalize).join(" ") }
                       .sort

    UI.stream_handler['inv_container'].clear_window
    UI.stream_handler['inv_container'].add_string "Inventory:"

    formatted_inv.each_with_index do |name, index|
      name = name.split(/ |\_/).map(&:capitalize).join(" ")
      UI.stream_handler['inv_container'].add_string (index < inv_size ? name : "...and other stuff")
      break if index >= inv_size
    end
  end
end

class ProfanityFE
  def initialize
    Curses.init_screen
    Curses.cbreak
    Curses.noecho
    Curses.stdscr.keypad(true)  # Enable keypad mode

    Profanity.set_terminal_title(Opts.char.capitalize)
    UI::Window.init

    start_up
    UI.stream_handler['xml_here'].add_string "Lines: #{Curses.lines} Columns: #{Curses.cols}"
  end

  def start_up
    UI.load_settings_file(false)
    UI.load_layout('default')
    TextWindow.list.each { |w| w.maxy.times { w.add_string "\n" } }
    Profanity.server = TCPSocket.open(Profanity.host, Profanity.port)
    Thread.new { sleep 15; Profanity.skip_server_time_offset = false }
    main_thread
    main_loop
  end
  
  def main_thread
    Thread.new {
      begin
        while (line = Profanity.server.gets)

          line.chomp!
          if line.empty?
            if UI.current_stream.nil?
              if UI.need_prompt
                UI.need_prompt = false
                Input.add_prompt(UI.stream_handler['main'], "")
              end
              UI.stream_handler['main'].add_string String.new
              UI.need_update = true
            end
          else
            if line =~ UI.bounty_regex
              line = "Bounty: #{line}"
              UI.current_stream = 'logons'
              UI.stream_handler['logons'].clear_window
              UI.handle_game_text(line)
              UI.current_stream = nil
            end

            if line =~ /^<output class="mono"/ || UI.next_line
              UI.next_line = true
              if line =~ /^You seem to be in one piece/
                parts_list = ["back","leftHand","rightHand","head","rightArm","abdomen","leftEye","leftArm","chest","rightLeft","neck","leftLeg","nsys","rightEye"]
                parts_list.each do |part|
                  handler = "injury:#{part}"
                  handler_list = UI.indicator_handler.keys.select { |key| key.include?(handler)}
                  handler_list.each { |item|
                    if UI.indicator_handler[item].update(0)
                      UI.need_update = true
                    end
                  }
                end
                UI.next_line = false
              end
            end

            if line =~ /Your worn items are/ || !UI.inv_response.empty?
              UI.inv_response << line
              if line =~ /<popStream\/>/
                Update.inventory(UI.inv_response)
                UI.inv_response = ''
              end
            end

            if line =~ /<nav rm='\d+'\/>/
              UI.new_room = true
              UI.room_name  = {}
              UI.room_desc  = {}
              UI.also_see   = {}
              UI.also_here  = {}
              UI.compass    = {}
            end

            if line =~ /<compass><dir value=/
              UI.new_room = false
            end

            while (start_pos = (line =~ /(<(prompt|spell|right|left|inv|style|compass).*?\2>|<.*?>)/))
              xml = Regexp.last_match(1)

              if line =~ /^  You also see/
                start_pos -= 2
                line.strip!
              end

              line.slice!(start_pos, xml.length)

              if xml =~ /^<prompt time=('|")([0-9]+)\1.*?>(.*?)&gt;<\/prompt>$/
                Profanity.put(prompt: "#{Regexp.last_match(3).clone}".strip)
                Profanity.update_process_title()
                unless Profanity.skip_server_time_offset
                  Profanity.server_time_offset = Time.now.to_f - Regexp.last_match(2).to_f
                  Profanity.skip_server_time_offset = true
                end
                new_prompt_text = "#{Regexp.last_match(3)}>"
                if UI.prompt_text != new_prompt_text
                  UI.need_prompt = false
                  UI.prompt_text = new_prompt_text
                  Input.add_prompt(UI.stream_handler['main'], "")
                  if prompt_window = UI.indicator_handler["prompt"]
                    init_prompt_height, init_prompt_width = UI.fix_layout_number(prompt_window.layout[0]), UI.fix_layout_number(prompt_window.layout[1])
                    new_prompt_width = new_prompt_text.length
                    prompt_window.resize(init_prompt_height, new_prompt_width)
                    prompt_width_diff = new_prompt_width - init_prompt_width
                    UI.command_window.resize(UI.fix_layout_number(UI.command_window_layout[0]), UI.fix_layout_number(UI.command_window_layout[1]) - prompt_width_diff)
                    ctop, cleft = UI.fix_layout_number(UI.command_window_layout[2]), UI.fix_layout_number(UI.command_window_layout[3]) + prompt_width_diff
                    UI.command_window.move(ctop, cleft)
                    prompt_window.label = new_prompt_text
                  end
                else
                  UI.need_prompt = true
                end
              elsif xml =~ /^<spell(?:>|\s.*?>)(.*?)<\/spell>$/
                if window = UI.indicator_handler['spell']
                  window.clear_window
                  window.refresh
                  window.label = Regexp.last_match(1)
                  window.update(Regexp.last_match(1) == 'None' ? 0 : 1)
                  UI.need_update = true
                end
              elsif xml =~ /^<streamWindow id='room' title='Room' subtitle=" \- (.*?)"/
                Profanity.put(room: Regexp.last_match(1))
                Profanity.update_process_title()
                if window = UI.indicator_handler["room"]
                  window.clear_window
                  window.label = Regexp.last_match(1)
                  window.update(Regexp.last_match(1) ? 0 : 1)
                  UI.need_update = true
                end
              elsif xml =~ /^<clearStream id=['"](\w+)['"]\/>$/
                # usage: _respond %[<clearStream id="familiar"/>]
                if UI.stream_handler[Regexp.last_match(1)]
                  UI.stream_handler[Regexp.last_match(1)].clear_window
                  UI.stream_handler[Regexp.last_match(1)].add_string(' ')
                end
              elsif xml =~ /^<(right|left)(?:>|\s.*?>)(.*?)<\/\1>/
                if window = UI.indicator_handler[Regexp.last_match(1)]
                  window.erase
                  in_hand = $2.split(/ |\_/).map(&:capitalize).join(" ")
                  window.label = in_hand
                  window.update(in_hand == 'Empty' ? 0 : 1)
                  UI.need_update = true
                end
              elsif xml =~ /^<roundTime value=('|")([0-9]+)\1/
                #stream_handler['xml_here'].add_string "Timer: #{countdown_handler['roundtime']}"
                #stream_handler['xml_here'].add_string "Timer: #{$2.to_i}"
                if window = UI.countdown_handler['roundtime']
                  temp_roundtime_end = Regexp.last_match(2).to_i
                  window.end_time = temp_roundtime_end
                  window.update_number
                  UI.need_update = true
                  Thread.new {
                    sleep 0.1
                    while (UI.countdown_handler['roundtime'].end_time == temp_roundtime_end) and (UI.countdown_handler['roundtime'].value > 0)
                      sleep 0.1
                      if UI.countdown_handler['roundtime'].update_number
                        UI.command_window.noutrefresh
                        Curses.doupdate
                      end
                    end
                  }
                end
                if window = UI.countdown_handler['bar_time']
                  temp_roundtime_end = Regexp.last_match(2).to_i
                  window.end_time = temp_roundtime_end
                  window.update
                  UI.need_update = true
                  Thread.new {
                    sleep 0.1
                    while (UI.countdown_handler['bar_time'].end_time == temp_roundtime_end) and (UI.countdown_handler['bar_time'].value > 0)
                  #stream_handler['xml_here'].add_string "Timer: #{temp_roundtime_end}"
                      sleep 0.1
                      if UI.countdown_handler['bar_time'].update_buffer
                        UI.command_window.noutrefresh
                        Curses.doupdate
                      end
                    end
                  }
                end
              elsif xml =~ /^<castTime value=('|")([0-9]+)\1/
                #stream_handler['xml_here'].add_string "Timer: #{CountdownWindow.list} "
                if window = UI.countdown_handler['roundtime']
                  temp_casttime_end = Regexp.last_match(2).to_i
                  window.secondary_end_time = temp_casttime_end
                  window.update_number
                  UI.need_update = true
                  Thread.new {
                    while (UI.countdown_handler['roundtime'].secondary_end_time == temp_casttime_end) and (UI.countdown_handler['roundtime'].secondary_value > 0)
                  #stream_handler['xml_here'].add_string "Timer: #{temp_casttime_end}"
                      sleep 0.15
                      if UI.countdown_handler['roundtime'].update_number
                        UI.command_window.noutrefresh
                        Curses.doupdate
                      end
                    end
                  }
                end
                if window = UI.countdown_handler['bar_time']
                  temp_casttime_end = $2.to_i
                  window.secondary_end_time = temp_casttime_end
                  window.update
                  UI.need_update = true
                  Thread.new {
                    while (UI.countdown_handler['bar_time'].secondary_end_time == temp_casttime_end) and (UI.countdown_handler['bar_time'].secondary_value > 0)
                    #stream_handler['xml_here'].add_string "Timer: #{temp_casttime_end}"
                      sleep 0.15
                      if UI.countdown_handler['bar_time'].update_buffer
                        UI.command_window.noutrefresh
                        Curses.doupdate
                      end
                    end
                  }
                end
              elsif xml =~ /^<compass/
                current_dirs = xml.scan(/<dir value="(.*?)"/).flatten
                [ 'up', 'down', 'out', 'n', 'ne', 'e', 'se', 's', 'sw', 'w', 'nw' ].each { |dir|
                  dir_update = current_dirs.include?(dir) ? 1 : 0
                  UI.indicator_handler["compass:#{dir}"].update(dir_update)
                }
                UI.new_room = false
                UI.need_update = true
              elsif xml =~ /^<progressBar id='encumlevel' value='([0-9]+)' text='(.*?)'/
                #stream_handler['xml_here'].add_string "#{xml}"
                if window = UI.progress_handler['encumbrance']
                  #window.update($2 == 'Overloaded' ? 110 : $1.to_i)
                  if Regexp.last_match(2) == 'Overloaded'
                    value = 110
                  else
                    value = Regexp.last_match(1).to_i
                  end
                  if window.update(value, 110)
                    UI.need_update = true
                  end
                end
              elsif xml =~ /^<hand/

              elsif xml =~ /^<progressBar id='pbarStance' value='([0-9]+)'/
                if window = UI.progress_handler['stance']
                  if window.update(Regexp.last_match(1).to_i, 100)
                    UI.need_update = true
                  end
                end
              elsif xml =~ /^<progressBar id='mindState' value='(.*?)' text='(.*?)'/
                if window = UI.progress_handler['mind']
                  if Regexp.last_match(2) == 'saturated'
                    value = 110
                  else
                    value = Regexp.last_match(1).to_i
                  end
                  #stream_handler['xml_here'].add_string "#{xml}"
                  if window.update(value, 110)
                    UI.need_update = true
                  end
                end
              elsif xml =~ /^<progressBar id='(.*?)' value='[0-9]+' text='.*?\s+(\-?[0-9]+)\/([0-9]+)'/
                if window = UI.progress_handler[Regexp.last_match(1)]
                  if window.update(Regexp.last_match(2).to_i, Regexp.last_match(3).to_i)
                    UI.need_update = true
                  end
                end
              elsif xml == '<pushBold/>' || xml == '<b>'
                h = { :start => start_pos }
                if UI.preset['monsterbold']
                  h[:fg] = UI.preset['monsterbold'][0]
                  h[:bg] = UI.preset['monsterbold'][1]
                end
                UI.open_monsterbold.push(h)
              elsif xml == '<popBold/>' || xml == '</b>'
                if h = UI.open_monsterbold.pop
                  h[:end] = start_pos
                  UI.line_colors.push(h) if h[:fg] || h[:bg]
                end
              elsif xml =~ /^<preset id=('|")(.*?)\1>$/
                h = { :start => start_pos }
                if UI.preset[$2]
                  h[:fg] = UI.preset[$2][0]
                  h[:bg] = UI.preset[$2][1]
                end
                UI.open_preset.push(h)
              elsif xml == '</preset>'
                if h = UI.open_preset.pop
                  h[:end] = start_pos
                  UI.line_colors.push(h) if h[:fg] || h[:bg]
                end
              elsif xml =~ /^<color/
                h = { :start => start_pos }
                if xml =~ /\sfg=('|")(.*?)\1[\s>]/
                  h[:fg] = Regexp.last_match(2).downcase
                end
                if xml =~ /\sbg=('|")(.*?)\1[\s>]/
                  h[:bg] = Regexp.last_match(2).downcase
                end
                if xml =~ /\sul=('|")(.*?)\1[\s>]/
                  h[:ul] = Regexp.last_match(2).downcase
                end
                UI.open_color.push(h)
              elsif xml == '</color>'
                if h = UI.open_color.pop
                  h[:end] = start_pos
                  UI.line_colors.push(h)
                end
              elsif xml =~ /^<style id=('|")(.*?)\1/
                #stream_handler['xml_here'].add_string "$1: #{$1} $2: #{$2} Line: #{line}"
                if Regexp.last_match(2).empty?
                  if UI.open_style
                    UI.open_style[:end] = start_pos
                    if (UI.open_style[:start] < UI.open_style[:end]) && (UI.open_style[:fg] || UI.open_style[:bg])
                      UI.line_colors.push(UI.open_style)
                    end
                    UI.open_style = nil
                  end
                else
                  UI.open_style = { :start => start_pos }
                  if UI.preset[Regexp.last_match(2)]
                    UI.open_style[:fg] = UI.preset[Regexp.last_match(2)][0]
                    UI.open_style[:bg] = UI.preset[Regexp.last_match(2)][1]
                  end
                end
                if Regexp.last_match(2) == "roomDesc"
                  UI.room_desc = {}
                  UI.is_room = true
                  line = Input.get_links(line)
                end
              elsif xml =~ /^<resource picture=('|")(.*?)('|")/
                if line =~ /<style id="roomName" \/>(\[.*?\] \(.*?\)|\[.*?\])/
                  UI.current_stream = 'roomName'
                  UI.handle_game_text(Regexp.last_match(1))
                  UI.current_stream = nil
                end
              elsif xml =~ /^<(?:pushStream|component|compDef) id=("|')(.*?)\1[^>]*\/?>$/
                UI.current_stream = Regexp.last_match(2)

                # sets links for room objects
                if xml =~ /<(?:component|compDef) id='room objs'>/
                  line = Input.get_links(line)
                end

                # Formats the text for links and highlights
                game_text = line.slice!(0, start_pos)
                UI.handle_game_text(game_text)
              elsif xml =~ /^<popStream/ || xml == '</component>'
                game_text = line.slice!(0, start_pos)
                UI.handle_game_text(game_text)
                UI.current_stream = nil
              elsif xml =~ /clearContainer id="stow"/
                Update.stow_container(line)
              elsif xml =~ /^<(?:dialogdata|a|\/a|d|\/d|\/?component|label|skin|output)/
                if line =~ /^<dialogData id='(Active Spells|Buffs|Debuffs|Cooldowns)'/
                  UI::SpellWindow.update_spells(line)
                  UI.need_update = true
                end
              elsif xml =~ /^<indicator id=('|")Icon([A-Z]+)\1 visible=('|")([yn])/
                #stream_handler['xml_here'].add_string "$2.downcase??: #{$2.downcase}  $4: #{$4}" if $2.downcase == "poisoned"
                if window = UI.countdown_handler[$2.downcase]
                  window.active = (Regexp.last_match(4) == 'y')
                  if window.update
                    UI.need_update = true
                  end
                end
                handler = "other:" + Regexp.last_match(2).downcase
                if window = UI.indicator_handler[handler]
                  #stream_handler['xml_here'].add_string "$2.downcase: #{$2.downcase}  $4: #{$4}" if $2.downcase == "poisoned"
                  #stream_handler['xml_here'].add_string "#{$4 == 'n'}"
                  #if window.update($4 == 'y')
                  window.update(Regexp.last_match(4) == 'y' ? 1 : 0)
                  UI.need_update = true
                end
              elsif xml =~ /^<image id=('|")(back|leftHand|rightHand|head|rightArm|abdomen|leftEye|leftArm|chest|rightLeg|neck|leftLeg|nsys|rightEye)\1 name=('|")(.*?)\3/
                if Regexp.last_match(2) == 'nsys'
                  if window = UI.indicator_handler['nsys']
                    if rank = Regexp.last_match(4).slice(/[0-9]/)
                      if window.update(rank.to_i)
                        UI.need_update = true
                      end
                    else
                      if window.update(0)
                        UI.need_update = true
                      end
                    end
                  end
                else
                  handler = "injury:" + Regexp.last_match(2)
                  fix_value = { 'Injury1' => 1, 'Injury2' => 2, 'Injury3' => 3, 'Scar1' => 4, 'Scar2' => 5, 'Scar3' => 6 }

                  handler_list = UI.indicator_handler.keys.select { |key| key.include?(handler)}
                  handler_list.each { |item|
                     if UI.indicator_handler[item].update(fix_value[Regexp.last_match(4)] || 0)
                     UI.need_update = true
                     end
                  }
                end
              elsif xml =~ /^<LaunchURL src="([^"]+)"/
                Update.launch_browser(Regexp.last_match(1))       
              else
                nil
              end
            end

            UI.handle_game_text(line)

            # Clear some variables - Fixme: check what they do?
            UI.open_monsterbold.clear
            UI.open_preset.clear

          end
          #
          # delay screen update if there are more game lines waiting
          #
          if UI.need_update && !IO.select([Profanity.server], nil, nil, 0.01)
            UI.need_update = false
            UI.command_window.noutrefresh
            Curses.doupdate
          end
        end

        UI.stream_handler['main'].add_string ' *'
        UI.stream_handler['main'].add_string ' * Connection closed'
        UI.stream_handler['main'].add_string ' *'
        UI.command_window.noutrefresh
        Curses.doupdate
      rescue
        Profanity.log { |f| f.puts $!; f.puts $!.backtrace[0...4] }
        exit
      end
    } 
  end
  
  def main_loop(startup_commands = [])
    begin
      # Simulate sending the startup commands if provided
      send_startup_commands(startup_commands) unless startup_commands.empty?

      loop do
        ch = UI.command_window.getch

        Autocomplete.consume(ch, history: Input.command_history, buffer: Input.command_buffer)

        if Input.key_combo
          case key_combo[ch]
          when Proc
            Input.key_combo[ch].call
            Input.key_combo = nil
          when Hash
            Input.key_combo = Input.key_combo[ch]
          else
            Input.key_combo = nil
          end
        elsif Input.key_binding[ch].is_a?(Proc)
          Input.key_binding[ch].call
        elsif Input.key_binding[ch].is_a?(Hash)
          Input.key_combo = Input.key_binding[ch]
        elsif ch.is_a?(String)
          Input.command_window_put_ch(ch)
          UI.command_window.noutrefresh
          Curses.doupdate
        end
      end

    rescue => exception
      Profanity.log(exception.message)
      Profanity.log(exception.backtrace)
      raise exception
    ensure
      Profanity.server.close rescue()
      Curses.close_screen
    end 
  end

  def send_startup_commands(commands)
    commands.each do |command|
      next unless command.is_a?(String)

      # Simulate putting each character of the command into the command window
      command.each_char do |ch|
        Input.command_window_put_ch(ch)
      end

      # Simulate pressing "Enter"
      Input.command_window_put_ch("\n")

      # Execute the command
      Input.key_action['send_command'].call      
    end
    
    # refresh the UI after sending the command
    UI.command_window.noutrefresh
    Curses.doupdate
  end
end

# Sets up Curses, the UI, and starts
ProfanityFE.new




