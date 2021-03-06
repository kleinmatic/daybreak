module Daybreak
  # Daybreak::DB contains the public api for Daybreak, you may extend it like
  # any other Ruby class (i.e. to overwrite serialize and parse). It includes
  # Enumerable for functional goodies like map, each, reduce and friends.
  class DB
    include Enumerable

    # Create a new Daybreak::DB. The second argument is the default value
    # to store when accessing a previously unset key, this follows the
    # Hash standard.
    # @param [String] file the path to the db file
    # @param default the default value to store and return when a key is
    #  not yet in the database.
    # @yield [key] a block that will return the default value to store.
    # @yieldparam [String] key the key to be stored.
    def initialize(file, default=nil, &blk)
      @table  = {}
      @file_name = file
      @writer = Writer.new(@file_name)
      @default = block_given? ? blk : default
      read!
    end

    # Set a key in the database to be written at some future date. If the data
    # needs to be persisted immediately, call <tt>db.set(key, value, true)</tt>.
    # @param [#to_s] key the key of the storage slot in the database
    # @param value the value to store
    # @param [Boolean] sync if true, sync this value immediately
    def []=(key, value, sync = false)
      key = key.to_s
      write key, value, sync
      @table[key] = value
    end
    alias_method :set, :"[]="

    # set! flushes data immediately to disk.
    # @param [#to_s] key the key of the storage slot in the database
    # @param value the value to store
    def set!(key, value)
      set key, value, true
    end

    # Delete a key from the database
    # @param [#to_s] key the key of the storage slot in the database
    # @param [Boolean] sync if true, sync this deletion immediately
    def delete(key, sync = false)
      key = key.to_s
      write key, '', sync, true
      @table.delete key
    end

    # delete! immediately deletes the key on disk.
    # @param [#to_s] key the key of the storage slot in the database
    def delete!(key)
      delete key, true
    end

    # Retrieve a value at key from the database. If the default value was specified
    # when this database was created, that value will be set and returned. Aliased
    # as <tt>get</tt>.
    # @param [#to_s] key the value to retrieve from the database.
    def [](key)
      key = key.to_s
      if @table.has_key? key
        @table[key]
      elsif default?
        set key, Proc === @default ? @default.call(key) : @default
      end
    end
    alias_method :get, :"[]"

    # Iterate over the key, value pairs in the database.
    # @yield [key, value] blk the iterator for each key value pair.
    # @yieldparam [String] key the key.
    # @yieldparam value the value from the database.
    def each
      keys.each { |k| yield(k, get(k)) }
    end

    # Does this db have a default value.
    def default?
      !@default.nil?
    end

    # Does this db have a value for this key?
    # @param [key#to_s] key the key to check if the DB has a key.
    def has_key?(key)
      @table.has_key? key.to_s
    end

    # Return the keys in the db.
    # @return [Array<String>]
    def keys
      @table.keys
    end

    # Return the number of stored items.
    # @return [Integer]
    def length
      @table.keys.length
    end
    alias_method :size, :length

    # Serialize the data for writing to disk, if you don't want to use <tt>Marshal</tt>
    # overwrite this method.
    # @param value the value to be serialized
    # @return [String]
    def serialize(value)
      Marshal.dump(value)
    end

    # Parse the serialized value from disk, like serialize if you want to use a
    # different serialization method overwrite this method.
    # @param value the value to be parsed
    # @return [String]
    def parse(value)
      Marshal.load(value)
    end

    # Empty the database file.
    def empty!
      @writer.truncate!
      @table.clear
      read!
    end
    alias_method :clear, :empty!

    # Force all queued commits to be written to disk.
    def flush!
      @writer.flush!
    end

    # Close the database for reading and writing.
    def close!
      @writer.close!
    end

    # Compact the database to remove stale commits and reduce the file size.
    def compact!
      # Create a new temporary database
      tmp_file = @file_name + "-#{$$}-#{Thread.current.object_id}"
      copy_db  = self.class.new tmp_file

      # Copy the database key by key into the temporary table
      each do |key, value|
        copy_db.set(key, get(key))
      end
      copy_db.close!

      close!

      # Move the copy into place
      File.rename tmp_file, @file_name

      # Reopen this database
      @writer = Writer.new(@file_name)
      @table.clear
      read!
    end

    # Read all values from the log file. If you want to check for changed data
    # call this again.
    def read!
      buf = nil
      File.open(@file_name, 'rb') do |fd|
        fd.flock(File::LOCK_SH)
        buf = fd.read
      end
      until buf.empty?
        key, data, deleted = Record.deserialize(buf)
        if deleted
          @table.delete key
        else
          @table[key] = parse(data)
        end
      end
    end

    private

    def write(key, value, sync = false, delete = false)
      @writer.write([key, serialize(value), delete])
      flush! if sync
    end
  end
end
