module Input
  # Implement support for basic readline-style kill and yank (cut and paste)
  # commands.  Successive calls to delete_word, backspace_word, kill_forward, and
  # kill_line will accumulate text into the kill_buffer as long as no other
  # commands have changed the command buffer.  These commands call kill_before to
  # reset the kill_buffer if the command buffer has changed, add the newly
  # deleted text to the kill_buffer, and finally call kill_after to remember the
  # state of the command buffer for next time.
  
  Input.kill_before = proc {
    if Input.kill_last != Input.command_buffer || Input.kill_last_pos != Input.command_buffer_pos
      Input.kill_buffer = ''
      Input.kill_original = Input.command_buffer
    end
  }
  
  Input.kill_after = proc {
    Input.kill_last = Input.command_buffer.dup
    Input.kill_last_pos = Input.command_buffer_pos
  }

  Input.write_to_client = proc { |str, color|
    UI.stream_handler["main"].add_string str, [{:fg => color, :start => 0, :end => str.size}]
    UI.command_window.noutrefresh
    Curses.doupdate
  }

  Input.key_action['resize'] = proc {
    # fixme: re-word-wrap
    window = Window.new(0,0,0,0)
    window.refresh
    window.close
    first_text_window = true
    for window in TextWindow.list.to_a
      window.resize(UI.fix_layout_number(window.layout[0]), UI.fix_layout_number(window.layout[1]) - 1)
      window.move(UI.fix_layout_number(window.layout[2]), UI.fix_layout_number(window.layout[3]))
      window.scrollbar.resize(window.maxy, 1)
      window.scrollbar.move(window.begy, window.begx + window.maxx)
      window.scroll(-window.maxy)
      window.scroll(window.maxy)
      window.clear_scrollbar
      if first_text_window
        window.update_scrollbar
        first_text_window = false
      end
      window.noutrefresh
    end
    for window in [ IndicatorWindow.list.to_a, ProgressWindow.list.to_a, CountdownWindow.list.to_a ].flatten
      window.resize(UI.fix_layout_number(window.layout[0]), UI.fix_layout_number(window.layout[1]))
      window.move(UI.fix_layout_number(window.layout[2]), UI.fix_layout_number(window.layout[3]))
      window.noutrefresh
    end
    if UI.command_window
      UI.command_window.resize(UI.fix_layout_number(UI.command_window_layout[0]), UI.fix_layout_number(UI.command_window_layout[1]))
      UI.command_window.move(UI.fix_layout_number(UI.command_window_layout[2]), UI.fix_layout_number(UI.command_window_layout[3]))
      UI.command_window.noutrefresh
    end
    
    Curses.doupdate
  }

  Input.key_action['cursor_left'] = proc {
    if (Input.command_buffer_offset > 0) and (Input.command_buffer_pos - Input.command_buffer_offset == 0)
      Input.command_buffer_pos -= 1
      Input.command_buffer_offset -= 1
      UI.command_window.insch(Input.command_buffer[Input.command_buffer_pos])
    else
      Input.command_buffer_pos = [Input.command_buffer_pos - 1, 0].max
    end
    UI.command_window.setpos(0, Input.command_buffer_pos - Input.command_buffer_offset)
    UI.command_window.noutrefresh
    Curses.doupdate
  }

  Input.key_action['cursor_right'] = proc {
    if ((Input.command_buffer.length - Input.command_buffer_offset) >= (UI.command_window.maxx - 1)) and (Input.command_buffer_pos - Input.command_buffer_offset + 1) >= UI.command_window.maxx
      if Input.command_buffer_pos < Input.command_buffer.length
        UI.command_window.setpos(0,0)
        UI.command_window.delch
        Input.command_buffer_offset += 1
        Input.command_buffer_pos += 1
        UI.command_window.setpos(0, Input.command_buffer_pos - Input.command_buffer_offset)
        unless Input.command_buffer_pos >= Input.command_buffer.length
          UI.command_window.insch(Input.command_buffer[Input.command_buffer_pos])
        end
      end
    else
      Input.command_buffer_pos = [Input.command_buffer_pos + 1, Input.command_buffer.length].min
      UI.command_window.setpos(0, Input.command_buffer_pos - Input.command_buffer_offset)
    end
    UI.command_window.noutrefresh
    Curses.doupdate
  }

  Input.key_action['cursor_word_left'] = proc {
    if Input.command_buffer_pos > 0
      if m = Input.command_buffer[0...(Input.command_buffer_pos-1)].match(/.*(\w[^\w\s]|\W\w|\s\S)/)
        new_pos = m.begin(1) + 1
      else
        new_pos = 0
      end
      if (Input.command_buffer_offset > new_pos)
        UI.command_window.setpos(0, 0)
        Input.command_buffer[new_pos, (Input.command_buffer_offset - new_pos)].split('').reverse.each { |ch| UI.command_window.insch(ch) }
        Input.command_buffer_pos = new_pos
        Input.command_buffer_offset = new_pos
      else
        Input.command_buffer_pos = new_pos
      end
      UI.command_window.setpos(0, Input.command_buffer_pos - Input.command_buffer_offset)
      UI.command_window.noutrefresh
      Curses.doupdate
    end
  }

  Input.key_action['cursor_word_right'] = proc {
    if Input.command_buffer_pos < Input.command_buffer.length
      if m = Input.command_buffer[Input.command_buffer_pos..-1].match(/\w[^\w\s]|\W\w|\s\S/)
        new_pos = Input.command_buffer_pos + m.begin(0) + 1
      else
        new_pos = Input.command_buffer.length
      end
      overflow = new_pos - UI.command_window.maxx - Input.command_buffer_offset + 1
      if overflow > 0
        UI.command_window.setpos(0,0)
        overflow.times {
          UI.command_window.delch
          Input.command_buffer_offset += 1
        }
        UI.command_window.setpos(0, UI.command_window.maxx - overflow)
        UI.command_window.addstr Input.command_buffer[(UI.command_window.maxx - overflow + Input.command_buffer_offset),overflow]
      end
      Input.command_buffer_pos = new_pos
      UI.command_window.setpos(0, Input.command_buffer_pos - Input.command_buffer_offset)
      UI.command_window.noutrefresh
      Curses.doupdate
    end
  }

  Input.key_action['cursor_home'] = proc {
    Input.command_buffer_pos = 0
    UI.command_window.setpos(0, 0)
    for num in 1..Input.command_buffer_offset
      begin
        UI.command_window.insch(Input.command_buffer[Input.command_buffer_offset - num])
      rescue
        Profanity.log_file { |f| 
          f.puts "command_buffer: #{Input.command_buffer.inspect}"; 
          f.puts "command_buffer_offset: #{Input.command_buffer_offset.inspect}"; 
          f.puts "num: #{num.inspect}"; 
          f.puts $!; 
          f.puts $!.backtrace[0...4] 
        }
        exit
      end
    end
    Input.command_buffer_offset = 0
    UI.command_window.noutrefresh
    Curses.doupdate
  }

  Input.key_action['cursor_end'] = proc {
    if Input.command_buffer.length < (UI.command_window.maxx - 1)
      Input.command_buffer_pos = Input.command_buffer.length
      UI.command_window.setpos(0, Input.command_buffer_pos)
    else
      scroll_left_num = Input.command_buffer.length - UI.command_window.maxx + 1 - Input.command_buffer_offset
      UI.command_window.setpos(0, 0)
      scroll_left_num.times {
        UI.command_window.delch
        Input.command_buffer_offset += 1
      }
      Input.command_buffer_pos = Input.command_buffer_offset + UI.command_window.maxx - 1 - scroll_left_num
      UI.command_window.setpos(0, Input.command_buffer_pos - Input.command_buffer_offset)
      scroll_left_num.times {
        UI.command_window.addch(Input.command_buffer[Input.command_buffer_pos])
        Input.command_buffer_pos += 1
      }
    end
    UI.command_window.noutrefresh
    Curses.doupdate
  }

  Input.key_action['cursor_backspace'] = proc {
    if Input.command_buffer_pos > 0
      Input.command_buffer_pos -= 1
      if Input.command_buffer_pos == 0
        Input.command_buffer = Input.command_buffer[(Input.command_buffer_pos+1)..-1]
      else
        Input.command_buffer = Input.command_buffer[0..(Input.command_buffer_pos-1)] + Input.command_buffer[(Input.command_buffer_pos+1)..-1]
      end
      UI.command_window.setpos(0, Input.command_buffer_pos - Input.command_buffer_offset)
      UI.command_window.delch
      if (Input.command_buffer.length - Input.command_buffer_offset + 1) > UI.command_window.maxx
        UI.command_window.setpos(0, UI.command_window.maxx - 1)
        UI.command_window.addch Input.command_buffer[UI.command_window.maxx - Input.command_buffer_offset - 1]
        UI.command_window.setpos(0, Input.command_buffer_pos - Input.command_buffer_offset)
      end
      UI.command_window.noutrefresh
      Curses.doupdate
    end
  }

  Input.key_action['cursor_delete'] = proc {
    if (Input.command_buffer.length > 0) and (Input.command_buffer_pos < Input.command_buffer.length)
      if Input.command_buffer_pos == 0
        Input.command_buffer = Input.command_buffer[(Input.command_buffer_pos+1)..-1]
      elsif Input.command_buffer_pos < Input.command_buffer.length
        Input.command_buffer = Input.command_buffer[0..(Input.command_buffer_pos-1)] + Input.command_buffer[(Input.command_buffer_pos+1)..-1]
      end
      UI.command_window.delch
      if (Input.command_buffer.length - Input.command_buffer_offset + 1) > UI.command_window.maxx
        UI.command_window.setpos(0, UI.command_window.maxx - 1)
        UI.command_window.addch Input.command_buffer[UI.command_window.maxx - Input.command_buffer_offset - 1]
        UI.command_window.setpos(0, Input.command_buffer_pos - Input.command_buffer_offset)
      end
      UI.command_window.noutrefresh
      Curses.doupdate
    end
  }

  Input.key_action['cursor_backspace_word'] = proc {
    num_deleted = 0
    deleted_alnum = false
    deleted_nonspace = false
    while Input.command_buffer_pos > 0 do
      next_char = Input.command_buffer[Input.command_buffer_pos - 1]
      if num_deleted == 0 || (!deleted_alnum && next_char.punct?) || (!deleted_nonspace && next_char.space?) || next_char.alnum?
        deleted_alnum = deleted_alnum || next_char.alnum?
        deleted_nonspace = !next_char.space?
        num_deleted += 1
        Input.kill_before.call
        Input.kill_buffer = next_char + Input.kill_buffer
        Input.key_action['cursor_backspace'].call
        Input.kill_after.call
      else
        break
      end
    end
  }

  Input.key_action['cursor_delete_word'] = proc {
    num_deleted = 0
    deleted_alnum = false
    deleted_nonspace = false
    while Input.command_buffer_pos < Input.command_buffer.length do
      next_char = Input.command_buffer[Input.command_buffer_pos]
      if num_deleted == 0 || (!deleted_alnum && next_char.punct?) || (!deleted_nonspace && next_char.space?) || next_char.alnum?
        deleted_alnum = deleted_alnum || next_char.alnum?
        deleted_nonspace = !next_char.space?
        num_deleted += 1
        Input.kill_before.call
        Input.kill_buffer = Input.kill_buffer + next_char
        Input.key_action['cursor_delete'].call
        Input.kill_after.call
      else
        break
      end
    end
  }

  Input.key_action['cursor_kill_forward'] = proc {
    if Input.command_buffer_pos < Input.command_buffer.length
      Input.kill_before.call
      if Input.command_buffer_pos == 0
        Input.kill_buffer = Input.kill_buffer + Input.command_buffer
        Input.command_buffer = ''
      else
        Input.kill_buffer = Input.kill_buffer + Input.command_buffer[Input.command_buffer_pos..-1]
        Input.command_buffer = Input.command_buffer[0..(Input.command_buffer_pos-1)]
      end
      Input.kill_after.call
      UI.command_window.clrtoeol
      UI.command_window.noutrefresh
      Curses.doupdate
    end
  }

  Input.key_action['cursor_kill_line'] = proc {
    if Input.command_buffer.length != 0
      Input.kill_before.call
      Input.kill_buffer = Input.kill_original
      Input.command_buffer = ''
      Input.command_buffer_pos = 0
      Input.command_buffer_offset = 0
      Input.kill_after.call
      UI.command_window.setpos(0, 0)
      UI.command_window.clrtoeol
      UI.command_window.noutrefresh
      Curses.doupdate
    end
  }

  Input.key_action['cursor_yank'] = proc {
    Input.kill_buffer.each_char { |c| Input.command_window_put_ch(c) }
  }

  Input.key_action['switch_current_window'] = proc {
    if current_scroll_window = TextWindow.list[0]
      current_scroll_window.clear_scrollbar
    end
    TextWindow.list.push(TextWindow.list.shift)
    if current_scroll_window = TextWindow.list[0]
      current_scroll_window.update_scrollbar
    end
    UI.command_window.noutrefresh
    Curses.doupdate
  }

  Input.key_action['scroll_current_window_up_one'] = proc {
    if current_scroll_window = TextWindow.list[0]
      current_scroll_window.scroll(-1)
    end
    UI.command_window.noutrefresh
    Curses.doupdate
  }

  Input.key_action['scroll_current_window_down_one'] = proc {
    if current_scroll_window = TextWindow.list[0]
      current_scroll_window.scroll(1)
    end
    UI.command_window.noutrefresh
    Curses.doupdate
  }

  Input.key_action['scroll_thought_up'] = proc {
    if current_scroll_window = TextWindow.list[1]
      current_scroll_window.scroll(-1)
    end
    UI.command_window.noutrefresh
    Curses.doupdate
  }

  Input.key_action['scroll_thought_down'] = proc {
    if current_scroll_window = TextWindow.list[1]
      current_scroll_window.scroll(1)
    end
    UI.command_window.noutrefresh
    Curses.doupdate
  }

  Input.key_action['scroll_current_window_up_page'] = proc {
    if current_scroll_window = TextWindow.list[0]
      current_scroll_window.scroll(0 - current_scroll_window.maxy + 1)
    end
    UI.command_window.noutrefresh
    Curses.doupdate
  }

  Input.key_action['scroll_current_window_down_page'] = proc {
    if current_scroll_window = TextWindow.list[0]
      current_scroll_window.scroll(current_scroll_window.maxy - 1)
    end
    UI.command_window.noutrefresh
    Curses.doupdate
  }

  Input.key_action['scroll_current_window_bottom'] = proc {
    if current_scroll_window = TextWindow.list[0]
      current_scroll_window.scroll(current_scroll_window.max_buffer_size)
    end
    UI.command_window.noutrefresh
    Curses.doupdate
  }

  Input.key_action['autocomplete'] = proc { |idx|
    Autocomplete.wrap do 
      current = Input.command_buffer.dup
      history = Input.command_history.map(&:strip).reject(&:empty?).compact.uniq

      # collection of possibilities
      possibilities = []

      unless current.strip.empty?
        history.each do |historical|
          possibilities.push(historical) if Autocomplete.compare(current, historical)
        end
      end

      if possibilities.size == 0
        Input.write_to_client.call "[autocomplete] no suggestions", UI.auto_highlight
      end

      if possibilities.size > 1
        # we should autoprogress the command input until there 
        # is a divergence in the possible commands
        divergence = Autocomplete.find_branch(possibilities)
        
        Input.command_buffer = divergence
        Input.command_buffer_offset = [ (Input.command_buffer.length - UI.command_window.maxx + 1), 0 ].max
        Input.command_buffer_pos = Input.command_buffer.length
        UI.command_window.addstr divergence[current.size..-1]
        UI.command_window.setpos(0, divergence.size)

        Input.write_to_client.call("[autocomplete:#{possibilities.size}]", UI.auto_highlight)
        possibilities.each_with_index do |command, i| 
          Input.write_to_client.call("[#{i}] #{command}", UI.auto_highlight) end
      end

      idx = 0 if possibilities.size == 1

      if idx && possibilities[idx]
        Input.command_buffer = possibilities[idx]
        Input.command_buffer_offset = [ (Input.command_buffer.length - UI.command_window.maxx + 1), 0 ].max
        Input.command_buffer_pos = Input.command_buffer.length
        UI.command_window.addstr possibilities.first[current.size..-1]
        UI.command_window.setpos(0, possibilities.first.size)
        Curses.doupdate
      end
    end
  }

  Input.key_action['previous_command'] = proc {
    if Input.command_history_pos < (Input.command_history.length - 1)
      Input.command_history[Input.command_history_pos] = Input.command_buffer.dup
      Input.command_history_pos += 1
      Input.command_buffer = Input.command_history[Input.command_history_pos].dup
      Input.command_buffer_offset = [ (Input.command_buffer.length - UI.command_window.maxx + 1), 0 ].max
      Input.command_buffer_pos = Input.command_buffer.length
      UI.command_window.setpos(0, 0)
      UI.command_window.deleteln
      UI.command_window.addstr Input.command_buffer[Input.command_buffer_offset,(Input.command_buffer.length - Input.command_buffer_offset)]
      UI.command_window.setpos(0, Input.command_buffer_pos - Input.command_buffer_offset)
      UI.command_window.noutrefresh
      Curses.doupdate
    end
  }

  Input.key_action['next_command'] = proc {
    if Input.command_history_pos == 0
      unless Input.command_buffer.empty?
        Input.command_history[Input.command_history_pos] = Input.command_buffer.dup
        Input.command_history.unshift String.new
        Input.command_buffer.clear
        UI.command_window.deleteln
        Input.command_buffer_pos = 0
        Input.command_buffer_offset = 0
        UI.command_window.setpos(0,0)
        UI.command_window.noutrefresh
        Curses.doupdate
      end
    else
      Input.command_history[Input.command_history_pos] = Input.command_buffer.dup
      Input.command_history_pos -= 1
      Input.command_buffer = Input.command_history[Input.command_history_pos].dup
      Input.command_buffer_offset = [ (Input.command_buffer.length - UI.command_window.maxx + 1), 0 ].max
      Input.command_buffer_pos = Input.command_buffer.length
      UI.command_window.setpos(0, 0)
      UI.command_window.deleteln
      UI.command_window.addstr Input.command_buffer[Input.command_buffer_offset,(Input.command_buffer.length - Input.command_buffer_offset)]
      UI.command_window.setpos(0, Input.command_buffer_pos - Input.command_buffer_offset)
      UI.command_window.noutrefresh
      Curses.doupdate
    end
  }

  Input.key_action['switch_arrow_mode'] = proc {
    if Input.key_binding[Curses::KEY_UP] == Input.key_action['previous_command']
      Input.key_binding[Curses::KEY_UP] = Input.key_action['scroll_current_window_up_page']
      Input.key_binding[Curses::KEY_DOWN] = Input.key_action['scroll_current_window_down_page']
    else
      Input.key_binding[Curses::KEY_UP] = Input.key_action['previous_command']
      Input.key_binding[Curses::KEY_DOWN] = Input.key_action['next_command']
    end
  }

  Input.key_action['send_command'] = proc {
    cmd = Input.command_buffer.dup
    Input.command_buffer.clear
    Input.command_buffer_pos = 0
    Input.command_buffer_offset = 0
    UI.need_prompt = false

    if window = UI.stream_handler['main']
      Input.add_prompt(window, cmd)
    end
    
    UI.command_window.deleteln
    UI.command_window.setpos(0,0)
    UI.command_window.noutrefresh
    Curses.doupdate
    Input.command_history_pos = 0
    # Remember all digit commands because they are likely spells for voodoo.lic
    if (cmd.length >= Input.command_history_min || cmd.digits?) and (cmd != Input.command_history[1])
      if Input.command_history[0].nil? || Input.command_history[0].empty?
        Input.command_history[0] = cmd
      else
        Input.command_history.unshift cmd
      end
      Input.command_history.unshift String.new
    end
    if cmd =~ /^\.quit|^\.reload/i
      exit
    elsif cmd =~ /^\.key/i
      window = UI.stream_handler['main']
      window.add_string("* ")
      window.add_string("* Waiting for key press...")
      UI.command_window.noutrefresh
      Curses.doupdate
      window.add_string("* Detected keycode: #{UI.command_window.getch.to_s}")
      window.add_string("* ")
      Curses.doupdate
    #elsif cmd =~ /^\.mouse/i
      
    #	stream_handler['xml_here'].add_string "Works"
    elsif cmd =~ /^\.copy/
      # fixme
      system "cmd.exe /c start microsoft-edge:http://www.cnn.com/"
    elsif cmd =~ /^\.fixcolor/i
      if UI::Window.custom_colors
        UI::Window.get_color_id_lookup.each { |code,id|
          Curses.init_color(id, ((code[0..1].to_s.hex/255.0)*1000).round, ((code[2..3].to_s.hex/255.0)*1000).round, ((code[4..5].to_s.hex/255.0)*1000).round)
        }
      end
    elsif cmd =~ /^\.resync/i
      Profanity.skip_server_time_offset = false
    #elsif cmd =~ /^\.reload/i
      #stream_handler['xml_here'].add_string "Called"
    #	load_settings_file.call(true)
      #Curses.endwin()
    elsif cmd =~ /^\.layout\s+(.+)/
      UI.load_settings_file(false)
      #load_layout.call($1)
      UI.load_layout('default')	
      Input.key_action['resize'].call
    elsif cmd =~ /^\.arrow/i
      Input.key_action['switch_arrow_mode'].call
    elsif cmd =~ /^\.e (.*)/
      eval(cmd.sub(/^\.e /, ''))
    elsif cmd =~ /^\.test/i
      #window = stream_handler['main']
      #window.add_string(" NCURSES_KEY_A1: #{NCURSES_KEY_A1.to_s}")
      #window.add_string(" get_color_id('4a4a4a'): #{get_color_id('4a4a4a')}")
      # 50.times do
        # stream_handler['xml_here'].add_string(" get_color_id('4a4a4a'): #{get_color_id('4a4a4a')}")
      # end
      # window.add_string("#{COLOR_PAIR_HISTORY.length}")
     # window.add_string(" get_color_pair_id(MAIN_FG, MAIN_BG): #{get_color_pair_id(MAIN_FG, MAIN_BG)}")
     # window.add_string(" Curses::color_pair(get_color_pair_id(MAIN_FG, MAIN_BG)): #{Curses::color_pair(get_color_pair_id(MAIN_FG, MAIN_BG))}")
      
      # COLOR_ID_LOOKUP.each { |code,id|
          # window.add_string(" code: #{code} id: #{id}")
        # }
          
      #Curses.doupdate
      # Main loop
      
      window = UI.stream_handler['main']
      window.add_string("* ")
      window.add_string("* Waiting for key press...")
      window.noutrefresh
      Curses.doupdate

      # Read the first key press
      key = UI.command_window.getch

      if key == Curses::KEY_A1
        # Detected a keypad key
        window.add_string("* Detected keypad key: #{key.to_s}")
      elsif key >= 256 && key <= 265
        # Detected a key from the numeric keypad
        window.add_string("* Detected numeric keypad key: #{key.to_s}")
      else
        # Detected a regular key
        window.add_string("* Detected regular key: #{key.to_s}")
      end

      window.add_string("* ")
      Curses.doupdate  
    else
      Profanity.server.puts cmd.sub(/^\./, ';')
    end
  }

  Input.key_action['send_last_command'] = proc {
    if cmd = Input.command_history[1]
      if window = UI.stream_handler['main']
        Input.add_prompt(window, cmd)
        #window.add_string(">#{cmd}", [ h={ :start => 0, :end => (cmd.length + 1), :fg => '555555' } ])
        UI.command_window.noutrefresh
        Curses.doupdate
      end
      if cmd =~ /^\.quit/i
        exit
      elsif cmd =~ /^\.fixcolor/i
        if UI::Window.custom_colors
          UI::Window.get_color_id_lookup.each { |code,id|
            Curses.init_color(id, ((code[0..1].to_s.hex/255.0)*1000).round, ((code[2..3].to_s.hex/255.0)*1000).round, ((code[4..5].to_s.hex/255.0)*1000).round)
          }
        end
      elsif cmd =~ /^\.resync/i
        Profanity.skip_server_time_offset = false
      elsif cmd =~ /^\.arrow/i
        Input.key_action['switch_arrow_mode'].call
      elsif cmd =~ /^\.e (.*)/
        eval(cmd.sub(/^\.e /, ''))
      else
        Profanity.server.puts cmd.sub(/^\./, ';')
      end
    end
  }

  Input.key_action['send_second_last_command'] = proc {
    if cmd = Input.command_history[2]
      if window = UI.stream_handler['main']
        Input.add_prompt(window, cmd)
        #window.add_string(">#{cmd}", [ h={ :start => 0, :end => (cmd.length + 1), :fg => '555555' } ])
        UI.command_window.noutrefresh
        Curses.doupdate
      end
      if cmd =~ /^\.quit/i
        exit
      elsif cmd =~ /^\.fixcolor/i
        if UI::Window.custom_colors
          UI::Window.get_color_id_lookup.each { |code,id|
            Curses.init_color(id, ((code[0..1].to_s.hex/255.0)*1000).round, ((code[2..3].to_s.hex/255.0)*1000).round, ((code[4..5].to_s.hex/255.0)*1000).round)
          }
        end
      elsif cmd =~ /^\.resync/i
        Profanity.skip_server_time_offset = false
      elsif cmd =~ /^\.arrow/i
        Input.key_action['switch_arrow_mode'].call
      elsif cmd =~ /^\.e (.*)/
        eval(cmd.sub(/^\.e /, ''))
      else
        Profanity.server.puts cmd.sub(/^\./, ';')
      end
    end
  }
end

