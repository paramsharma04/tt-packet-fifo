## How it works

A FIFO that stores and releases data one packet at a time rather than one word at a time.

Words arrive marked with SOP (start of packet) and EOP (end of packet). They are written into
an 8-deep buffer using a *speculative* write pointer. A separate *committed* write pointer
tracks what the reader is allowed to see, and the read side compares against the committed
pointer only. A packet in progress is therefore invisible downstream.

When EOP arrives, one of two things happens. If the packet is clean, the committed pointer
jumps forward to include it and the whole packet becomes readable at once. If the packet is
bad — the upstream sender asserted PKT_ERR, or the packet was longer than the buffer — the
speculative pointer is rolled back to the committed pointer, discarding the packet entirely,
and the DROP flag is raised.

This means a reader can never observe a partial or malformed packet, which is the property
that matters in networking hardware: a truncated packet downstream is worse than no packet.

Data is 8 bits wide and the buffer holds 8 words, so the longest packet that can be stored
is 8 words. Anything longer is dropped rather than truncated.

## How to test

Drive a packet in by asserting WR_EN with SOP on the first word and EOP on the last, putting
data on the input pins.

- **Good packet:** write three words with SOP on the first and EOP on the third. EMPTY stays
  high until EOP arrives, then goes low. Assert RD_EN repeatedly and the three words come
  back in order.
- **Bad packet:** repeat the above, but also assert PKT_ERR on the EOP word. EMPTY stays high
  — nothing was committed — and DROP goes high.
- **Oversized packet:** write ten words without an EOP, then send EOP. The packet exceeds the
  8-word buffer, so it is dropped whole and DROP goes high.
- **Single-word packet:** assert SOP and EOP together on one word. It commits normally.

After any drop, the next good packet should commit as usual and clear DROP.

## External hardware

None. Switches or a logic analyser on the input pins and LEDs on the outputs are sufficient.
