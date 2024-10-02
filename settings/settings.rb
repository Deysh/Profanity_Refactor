module Settings
  @lock = Mutex.new

  #APP_DIR = Dir.home + "/.profanity"
  APP_DIR="/mnt/c/Users/mperm/OneDrive/Mark/Gemstone/ProfanityFE"
	##
	## setup app dir
	##
	FileUtils.mkdir_p APP_DIR

	def self.file(path)
		APP_DIR + "/" + path
	end

  def self.read(file)
    @lock.synchronize do
      return File.read(file)
    end
  end

  def self.from_xml(file)
    bin = Settings.read(file)
    REXML::Document.new(bin).root
  end
end

module Input
  class << self
    attr_accessor :command_buffer, :command_buffer_pos, :command_buffer_offset, :command_history, 
                  :command_history_pos, :command_history_max, :command_history_min,  
                  :key_action, :key_binding, :kill_before, :kill_after, :kill_buffer, :kill_original, :kill_last, :kill_last_pos, :write_to_client,
                  :first_time, :stow_name, :key_combo
  end

  self.command_buffer         = "" 
  self.command_buffer_pos     = 0  
  self.command_buffer_offset  = 0  
  self.command_history        = [] 
  self.command_history_pos    = 0   
  self.command_history_max    = 20 # not used?
  self.command_history_min    = 4  
  self.key_action             = {}
  self.key_binding            = {}
  
  self.kill_before            = nil
  self.kill_after             = nil
  self.kill_buffer            = ''
  self.kill_original          = ''
  self.kill_last              = ''
  self.kill_last_pos          = 0
  self.write_to_client        = nil
  
  self.first_time             = true
  self.key_combo              = nil
end

module UI
  class << self
    attr_accessor :need_prompt, :prompt_text, :stream_handler, :indicator_handler, :progress_handler, :countdown_handler,
                  :command_window, :command_window_layout, :preset, :settings_lock, :auto_highlight, :layout,
                  :main_fg, :main_bg, :uroom, :room_name, :room_desc, :also_see, :also_here, :compass, :new_room, :old_set, :room_array, :need_update,
                  :line_colors, :open_style, :open_color, :current_stream, :is_room, :bounty_regex, :room_regex, :inv_response, :next_line,
                  :open_monsterbold, :open_preset
  end
  
  self.need_prompt            = false 
  self.prompt_text            = ">"  
  self.stream_handler         = {}   
  self.indicator_handler      = {}   
  self.progress_handler       = {}   
  self.countdown_handler      = {}   
  self.command_window         = nil  
  self.command_window_layout  = nil
  self.preset                 = {} 
  self.settings_lock          = Mutex.new
  self.auto_highlight         = "a6e22e"
  self.layout                 = {}
  self.main_fg                = ""
  self.main_bg                = ""
   
  # Room updates
  self.uroom                  = nil
  self.room_name              = {}
  self.room_desc              = {}
  self.also_see               = {}
  self.also_here              = {}
  self.compass                = {}
  self.new_room               = true
  self.old_set                = {}
  self.room_array             = [self.room_name,self.room_desc,self.also_see,self.also_here,self.compass]
  
  # Thread & handle_room variables
  self.need_update            = false 
  self.line_colors            = []
  self.open_style             = nil
  self.open_color             = []
  self.current_stream         = nil
  self.is_room                = false
  self.inv_response           = ''
  self.next_line              = false
  self.open_monsterbold       = []
  self.open_preset            = []

  
  self.bounty_regex = Regexp.union(
    /You are not currently assigned/,
    /You have made contact/,
    /The gem dealer/,
    /You have been tasked to/,
    /The Taskmaster told you/,
    /You have succeeded in your/,
    /You succeeded in your task/,
    /^You have located (?:an?|some) (?<item>.+) and should bring it back to/,
    /The child you were tasked to rescue is gone and your task is failed/,
  )
  
  self.room_regex = Regexp.union(
    /<nav rm='.*?'\/>/,
    /<style id=""\/><style id="roomDesc"\/>.*?<style/,
    /Also here:/,
    /<component id='room objs'>/,
    /Obvious (?:paths|exits)/,
    /<compass><dir value=/,
    /<resource picture="0"\/><style id="roomName"/,
  )

end