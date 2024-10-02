class ProfanityHook
  @@downstream_hooks ||= Hash.new

  def ProfanityHook.add(name, action)
    unless action.class == Proc
      echo "ProfanityHook: not a Proc (#{action})"
      return false
    end
    @@downstream_hooks[name] = action
  end

  def ProfanityHook.run(server_string)
    for key in @@downstream_hooks.keys
      return nil if server_string.nil?
      begin
        server_string = @@downstream_hooks[key].call(server_string.dup) if server_string.is_a?(String)
      rescue
        @@downstream_hooks.delete(key)
        respond "--- Lich: ProfanityHook: #{$!}"
        respond $!.backtrace.first
      end
    end
    return server_string
  end

  def ProfanityHook.remove(name)    
    @@downstream_hooks.delete(name)
  end
end