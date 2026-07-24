defmodule Exfuse.Fs.Stat do
  @moduledoc "Normalized metadata returned by `Exfuse.Fs.stat/2`."

  @enforce_keys [:type, :mode, :size]
  defstruct [:type, :mode, :size, :mtime]

  @type t :: %__MODULE__{
          type: :directory | :file | :symlink | :other,
          mode: non_neg_integer(),
          size: non_neg_integer(),
          mtime: integer() | nil
        }
end
