defmodule Exfuse.Socket do
  @moduledoc """
  The long-lived filesystem session.
  """

  defstruct id: nil,
            runtime: nil,
            state: nil,
            assigns: %{}

  @type handle :: non_neg_integer
  @type t :: %__MODULE__{
          id: term,
          runtime: term,
          state: term,
          assigns: map
        }

  @spec new(term, term) :: t
  def new(runtime, state) do
    %__MODULE__{
      id: {self(), System.unique_integer([:positive, :monotonic])},
      runtime: runtime,
      state: state
    }
  end

  @spec put_state(t, term) :: t
  def put_state(%__MODULE__{} = socket, state), do: %{socket | state: state}

  @spec assign(t, atom, term) :: t
  def assign(%__MODULE__{} = socket, key, value),
    do: %{socket | assigns: Map.put(socket.assigns, key, value)}

  @spec get_assign(t, atom, term) :: term
  def get_assign(%__MODULE__{} = socket, key, default \\ nil),
    do: Map.get(socket.assigns, key, default)

  @spec put_handle(t, handle, term) :: t
  def put_handle(%__MODULE__{} = socket, handle, value) when is_integer(handle) and handle >= 0 do
    handles =
      socket
      |> get_assign(:handles, %{})
      |> Map.put(handle, value)

    assign(socket, :handles, handles)
  end

  @spec new_handle(t, term) :: {handle, t}
  def new_handle(%__MODULE__{} = socket, value) do
    handle = System.unique_integer([:positive, :monotonic])
    {handle, put_handle(socket, handle, value)}
  end

  @spec fetch_handle(t, handle) :: {:ok, term} | :error
  def fetch_handle(%__MODULE__{} = socket, handle),
    do: socket |> get_assign(:handles, %{}) |> Map.fetch(handle)

  @spec delete_handle(t, handle) :: t
  def delete_handle(%__MODULE__{} = socket, handle) do
    handles =
      socket
      |> get_assign(:handles, %{})
      |> Map.delete(handle)

    assign(socket, :handles, handles)
  end
end
