defmodule Exfuse.Fs.Entry do
  @moduledoc "One child returned by `Exfuse.Fs.list/2`."

  @enforce_keys [:name, :path, :type, :size]
  defstruct [:name, :path, :type, :size]

  @type t :: %__MODULE__{
          name: String.t(),
          path: String.t(),
          type: :directory | :file | :symlink | :other,
          size: non_neg_integer()
        }
end
