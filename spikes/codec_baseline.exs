# Copyright 2026 James Casey
# SPDX-License-Identifier: Apache-2.0
#
# Spike 4's Elixir baseline: the same operations as
# byte_codecs_spike_test.bt's testCodecCost, written as Bandit and HPAX
# write them. Run: elixir spikes/codec_baseline.exs
defmodule CodecBaseline do
  def h2_header(<<len::24, type::8, flags::8, _r::1, sid::31, rest::binary>>),
    do: {len, type, flags, sid, rest}

  def h2_header(_), do: nil

  def h2_frame(<<len::24, type::8, flags::8, _r::1, sid::31, payload::binary-size(len), rest::binary>>),
    do: {type, flags, sid, payload, rest}

  def h2_frame(_), do: nil

  def ws_frame(<<fin::1, rsv::3, op::4, 1::1, len::7, key::binary-size(4), payload::binary-size(len), rest::binary>>)
      when len < 126,
      do: {fin, rsv, op, key, unmask(payload, key), rest}

  def ws_frame(_), do: nil

  def unmask(payload, key) do
    n = byte_size(payload)
    :crypto.exor(payload, binary_part(:binary.copy(key, div(n, 4) + 1), 0, n))
  end

  def hpack_int(bin, prefix) do
    skip = 8 - prefix
    max = Bitwise.bsl(1, prefix) - 1

    case bin do
      <<_::size(^skip), v::size(^prefix), rest::binary>> when v < max -> {v, rest}
      <<_::size(^skip), _::size(^prefix), rest::binary>> -> hpack_rest(rest, max, 0)
      _ -> nil
    end
  end

  defp hpack_rest(<<0::1, v::7, rest::binary>>, acc, m), do: {acc + Bitwise.bsl(v, m), rest}
  defp hpack_rest(<<1::1, v::7, rest::binary>>, acc, m), do: hpack_rest(rest, acc + Bitwise.bsl(v, m), m + 7)
  defp hpack_rest(_, _, _), do: nil

  def h2_serialize(type, flags, sid, payload),
    do: [<<byte_size(payload)::24, type::8, flags::8, 0::1, sid::31>>, payload]

  def hpack_encode(value, prefix, flags) do
    max = Bitwise.bsl(1, prefix) - 1
    if value < max, do: <<Bitwise.bor(flags, value)>>, else: [<<Bitwise.bor(flags, max)>> | rest(value - max)]
  end

  defp rest(v) when v >= 128, do: [<<Bitwise.bor(Bitwise.band(v, 127), 128)>> | rest(Bitwise.bsr(v, 7))]
  defp rest(v), do: [<<v>>]

  def time(n, f) do
    Enum.each(1..1000, fn _ -> f.() end)
    {us, _} = :timer.tc(fn -> loop(n, f) end)
    us
  end

  defp loop(0, _), do: :ok
  defp loop(n, f), do: (f.(); loop(n - 1, f))
end

n = 100_000
header = <<0, 0, 5, 1, 4, 0, 0, 0, 3, "hello">>
masked = <<129, 133, 55, 250, 33, 61, 127, 159, 77, 81, 88>>
hpack = <<255, 154, 10>>
big = :binary.copy("q", 65536)
key = <<55, 250, 33, 61>>
ns = fn us -> div(us * 1000, n) end

IO.puts(
  Enum.join(
    [
      "elixir_codecs ops=#{n}",
      "h2_header_ns=#{ns.(CodecBaseline.time(n, fn -> CodecBaseline.h2_header(header) end))}",
      "h2_frame_ns=#{ns.(CodecBaseline.time(n, fn -> CodecBaseline.h2_frame(header) end))}",
      "ws_masked_frame_ns=#{ns.(CodecBaseline.time(n, fn -> CodecBaseline.ws_frame(masked) end))}",
      "hpack_int_decode_ns=#{ns.(CodecBaseline.time(n, fn -> CodecBaseline.hpack_int(hpack, 5) end))}",
      "h2_serialize_iodata_ns=#{ns.(CodecBaseline.time(n, fn -> CodecBaseline.h2_serialize(1, 4, 3, "hello") end))}",
      "h2_serialize_binary_ns=#{ns.(CodecBaseline.time(n, fn -> IO.iodata_to_binary(CodecBaseline.h2_serialize(1, 4, 3, "hello")) end))}",
      "hpack_int_encode_ns=#{ns.(CodecBaseline.time(n, fn -> CodecBaseline.hpack_encode(1337, 5, 0) end))}",
      "ws_unmask_64KiB_us=#{div(CodecBaseline.time(1000, fn -> CodecBaseline.unmask(big, key) end), 1000)}"
    ],
    " "
  )
)
