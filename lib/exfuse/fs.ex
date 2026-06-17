defmodule Exfuse.Fs do
  @moduledoc """
  Filesystems implement FUSE operations with route macros or `handle_event/3`.
  `Exfuse.mount/3` mounts one filesystem process; routes define the directory
  tree below that mount point.

      init do
        opts
      end

      readdir "/" do
        {:reply, ["docs"], socket}
      end

      getattr "/" do
        {:reply, dir(), socket}
      end

      readdir "/docs" do
        {:reply, Map.keys(state), socket}
      end

      getattr "/docs" do
        {:reply, dir(), socket}
      end

      getattr "/docs/:name" do
        {:reply, file(size: byte_size(state[name])), socket}
      end

      read "/docs/:name" do
        {:reply, read_chunk(state[name], event), socket}
      end

      plug "/media/*path", MyApp.MediaFile

  `:name` binds one path segment as a binary. `*name` binds the remaining path
  tail as a list of segments, and bare `*` matches the remaining tail without
  binding it. Route blocks can read `event`, `socket` and `state`; params are
  endpoint variables, not fields on the socket. `init` blocks can read
  `mount_point` and `opts`.

  Or implement `handle_event/3` and pattern match on the event payload:

      def handle_event(:getattr, %{path: "/"}, socket) do
        {:reply, dir(), socket}
      end

      def handle_event(:read, %{path: "/docs/" <> _} = event, socket) do
        {:reply, read_chunk(event), socket}
      end

      def handle_event(_op, _event, socket), do: {:error, :enoent, socket}

  The payload is a map. Every payload includes `path`, `uid`, `gid`, `pid`, and
  `umask`. Extra fields:

    * `:read` - `flags`, `handle`, `offset`, `size`
    * `:write` - `handle`, `offset`, `data`
    * `:open` - `flags`
    * `:create` - `mode`, `flags`
    * `:truncate` - `size`
    * `:rename` - `target`
    * `:mkdir` and `:chmod` - `mode`
    * `:chown` - `owner_uid`, `owner_gid`
    * `:flush` and `:release` - `flags`, `handle`
    * `:fsync` - `datasync`, `flags`, `handle`

  `plug/2` delegates every operation matching the path to an endpoint process.
  Endpoint processes are keyed by route params. A plugged module can define
  `init/1`; after that it receives packets through `handle_event/3`.

      defmodule MyApp.MediaFile do
        def init(socket) do
          {:ok, socket}
        end

        def handle_event(:read, %{params: %{file: file}} = event, socket) do
          {:reply, read_media(file, event), socket}
        end
      end
  """

  defmacro __using__(opts) do
    attribs_only? = Keyword.get(opts, :attribs, false)

    quote location: :keep do
      unquote(attrib_setup())
      unquote(unless attribs_only?, do: behaviour_setup())
    end
  end

  @doc """
  Builds a directory attribute reply for `getattr`.
  """
  defdelegate dir(opts \\ []), to: Exfuse.Fs.Dsl

  @doc """
  Builds a regular file attribute reply for `getattr`.
  """
  defdelegate file(opts \\ []), to: Exfuse.Fs.Dsl

  @doc """
  Builds a symlink attribute reply for `getattr`.
  """
  defdelegate symlink(opts \\ []), to: Exfuse.Fs.Dsl

  @type operation ::
          :readdir
          | :getattr
          | :readlink
          | :read
          | :write
          | :open
          | :create
          | :truncate
          | :unlink
          | :rename
          | :mkdir
          | :rmdir
          | :chmod
          | :chown
          | :flush
          | :release
          | :fsync

  @type event :: %{
          required(:path) => String.t(),
          optional(:uid) => non_neg_integer,
          optional(:gid) => non_neg_integer,
          optional(:pid) => non_neg_integer,
          optional(:umask) => non_neg_integer,
          optional(:flags) => integer,
          optional(:handle) => Exfuse.Socket.handle(),
          optional(:offset) => non_neg_integer,
          optional(:size) => non_neg_integer,
          optional(:mode) => non_neg_integer,
          optional(:data) => binary,
          optional(:target) => String.t(),
          optional(:owner_uid) => non_neg_integer,
          optional(:owner_gid) => non_neg_integer,
          optional(:datasync) => boolean
        }

  @type event_result ::
          {:noreply, Exfuse.Socket.t()}
          | {:reply, term, Exfuse.Socket.t()}
          | {:error, term, Exfuse.Socket.t()}

  @callback exfuse_init(String.t(), term) :: {:ok, term} | {:error, term}

  @callback handle_event(operation, event, Exfuse.Socket.t()) :: event_result

  defp behaviour_setup do
    quote do
      @behaviour Exfuse.Fs
      import Exfuse.Fs.Dsl,
        only: [
          init: 1,
          readdir: 2,
          getattr: 2,
          readlink: 2,
          read: 2,
          write: 2,
          open: 2,
          create: 2,
          truncate: 2,
          unlink: 2,
          rename: 2,
          mkdir: 2,
          rmdir: 2,
          chmod: 2,
          chown: 2,
          flush: 2,
          release: 2,
          fsync: 2,
          plug: 2,
          dir: 0,
          dir: 1,
          file: 0,
          file: 1,
          put_state: 2,
          symlink: 0,
          symlink: 1
        ]

      Module.register_attribute(__MODULE__, :exfuse_routes, accumulate: true)
      Module.register_attribute(__MODULE__, :exfuse_init, accumulate: false)
      @before_compile Exfuse.Fs.Dsl
    end
  end

  defp attrib_setup do
    quote do
      @error_noent 2
      @error_nosys 38
      @status_data 100
      @request_readdir 3
      @request_getattr 4
      @request_readlink 5
      @request_read 6
      @request_write 7
      @request_open 8
      @request_create 9
      @request_truncate 10
      @request_unlink 11
      @request_rename 12
      @request_mkdir 13
      @request_rmdir 14
      @request_chmod 15
      @request_chown 16
      @request_flush 17
      @request_release 18
      @request_fsync 19
      @attr_dir 1
      @attr_file 2
      @attr_symlink 3
      @magiccookie 3_223_410_092
    end
  end
end
