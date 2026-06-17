defmodule TestFs do
  use Exfuse.Fs

  def exfuse_init(mp, opts) do
    {:ok, {mp, opts}}
  end

  def handle_event(:readdir, _event, socket), do: {:reply, [], socket}

  def handle_event(:getattr, _event, socket), do: {:reply, {0o0755, @attr_dir, 0}, socket}

  def handle_event(:read, _event, socket), do: {:reply, "", socket}

  def handle_event(:readlink, _event, socket), do: {:reply, ".", socket}
  def handle_event(_op, _event, socket), do: {:error, :enoent, socket}
end
