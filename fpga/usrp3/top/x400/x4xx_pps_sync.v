//
// Copyright 2019 Ettus Research, A National Instruments Company
//
// SPDX-License-Identifier: LGPL-3.0-or-later
//
// Module: x4xx_pps_sync
// Description:
// This module encapsulates the PPS handling and the related LMK SYNC signal.

module x4xx_pps_sync #(
    parameter SIMULATION = 0 // lowers 10 MHz PPS base reference clock to 10 kHz to shorten test times
  )(
  // clock and reset
  input  wire base_ref_clk, // BRC
  input  wire pll_ref_clk,  // PRC
  input  wire ctrl_clk,     // CC
  input  wire radio_clk,    // RC

  input  wire brc_rst,

  // PPS
  input  wire pps_in, // BRC domain
  output wire pps_out_brc,
  output reg  pps_out_rc = 1'b0,

  // LMK control signal
  output reg  sync = 1'b0,

  // Control signals (CC domain)
  input  wire [1:0]  pps_select,
  input  wire        pll_sync_trigger,
  input  wire [7:0]  pll_sync_delay,
  output wire        pll_sync_done,
  input  wire [7:0]  pps_brc_delay,
  input  wire [25:0] pps_prc_delay,
  input  wire [1:0]  prc_rc_divider,
  input  wire        pps_rc_enabled,

  //signal for debugging
  output wire [1:0] debug
);

  `include "regmap/global_regs_regmap_utils.vh"

  //------------------------------------------------------------------
  // PPS Generation and Capturing (BRC domain)
  //------------------------------------------------------------------
  // divide 10 MHz to 10 kHz in case test mode is activated
  localparam FREQUENCY_10M = SIMULATION ? 32'd10_000 : 32'd10_000_000;
  localparam FREQUENCY_25M = 32'd25_000_000;

  // Generate internal PPS signals, each with a 25% duty cycle, based on
  // the different Reference Clock rates. Only one will be used at a time.
  // Available base reference clock rates are: 10 MHz, 25 MHz
  wire pps_int_10mhz_brc;
  pps_generator #(
     .CLK_FREQ(FREQUENCY_10M), .DUTY_CYCLE(25), .PIPELINE("OUT")
  ) pps_gen_10 (
     .clk(base_ref_clk), .reset(1'b0), .pps(pps_int_10mhz_brc)
  );
  wire pps_int_25mhz_brc;
  pps_generator #(
     .CLK_FREQ(FREQUENCY_25M), .DUTY_CYCLE(25), .PIPELINE("OUT")
  ) pps_gen_25 (
     .clk(base_ref_clk), .reset(1'b0), .pps(pps_int_25mhz_brc)
  );

  // Capture the external PPSs with a FF before sending them to the mux. To be safe,
  // we double-synchronize the external signals. If we meet timing (which we should)
  // then this is a two-cycle delay. If we don't meet timing, then it's 1-2 cycles
  // and our system timing is thrown off--but at least our downstream logic doesn't
  // go metastable!
  wire pps_ext_brc;
  synchronizer #(
    .FALSE_PATH_TO_IN(0)
  ) ext_pps_dsync (
    .clk(base_ref_clk), .rst(1'b0), .in(pps_in), .out(pps_ext_brc)
  );

  // Synchronize the select bits over to the reference clock as well. Note that this is
  // a vector, so we could have some invalid values creep through when changing.
  // See the note below as to why this is safe.
  wire [1:0] pps_select_brc;
  synchronizer #(
    .FALSE_PATH_TO_IN(1),
    .WIDTH(2)
  ) pps_select_dsync (
    .clk(base_ref_clk), .rst(1'b0), .in(pps_select), .out(pps_select_brc)
  );

  // PPS MUX - selects internal or external PPS.
  reg pps_brc = 1'b0;
  always @(posedge base_ref_clk) begin
    // It is possible when the vector is being double-synchronized
    // to the reference clock domain that there could be multiple bits
    // asserted simultaneously. This is not problematic because the order of operations
    // in the following selection mux should take over and only one PPS should win.
    // This could result in glitches, but that is expected during ANY PPS switchover
    // since the switch is performed asynchronously to the PPS signal.
    case (pps_select_brc)
      PPS_INT_10MHZ: begin
        pps_brc <= pps_int_10mhz_brc;
      end
      PPS_INT_25MHZ: begin
        pps_brc <= pps_int_25mhz_brc;
      end
      default: begin
        pps_brc <= pps_ext_brc;
      end
    endcase
  end

  // forward BRC based PPS to output
  assign pps_out_brc = pps_brc;


  //------------------------------------------------------------------
  // LMK sync generation (BRC domain)
  //------------------------------------------------------------------
  // detect rising edge of PPS
  reg  pps_brc_delayed;
  wire pps_rising_edge_brc;
  always @(posedge base_ref_clk) begin
    pps_brc_delayed <= pps_brc;
  end
  assign pps_rising_edge_brc = pps_brc & ~pps_brc_delayed;

  // transfer control signals to internal clock domain
  wire pll_sync_trigger_brc;
  synchronizer #(
    .FALSE_PATH_TO_IN(1)
  ) trigger_sync (
    .clk(base_ref_clk), .rst(1'b0), .in(pll_sync_trigger), .out(pll_sync_trigger_brc)
  );

  // There is no data coherency guaranteed by this synchronizer, but this is not
  // required. The information is derived in the same clock domain as the sync
  // trigger. Both information in the worst case arrive in the same clock cycle.
  // In the state machine the trigger is chaning the state to ARMED. The delay
  // value is required in the ARMED state. This way there is one more clock cycle
  // for this synchronizer to propagate the correct value of all bits.
  wire [7:0] pll_sync_delay_brc;
  synchronizer #(
    .FALSE_PATH_TO_IN(1),
    .WIDTH(8)
  ) delay_trigger_sync (
    .clk(base_ref_clk), .rst(1'b0), .in(pll_sync_delay), .out(pll_sync_delay_brc)
  );

  // synchronization state machine
  localparam IDLE  = 2'd0;
  localparam ARMED = 2'd1;
  localparam COUNT = 2'd2;
  localparam DONE  = 2'd3;

  reg [7:0] delay_counter_brc = 8'd0;
  reg [1:0] state = IDLE;
  reg       pll_sync_done_brc = 1'b0;
  reg       sync_int = 1'b0;

  always @(posedge base_ref_clk) begin
    if (brc_rst) begin
      sync_int <= 1'b0;
      pll_sync_done_brc <= 1'b0;
      state <= IDLE;
    end
    else begin
      case (state)
        IDLE: begin
          //wait for trigger from control interface
          if (pll_sync_trigger_brc) begin
            state <= ARMED;
          end
        end

        ARMED: begin
          // wait for the rising edge of PPS and reset counter
          delay_counter_brc <= pll_sync_delay_brc;
          if (pps_rising_edge_brc) begin
            state <= COUNT;
          end
        end

        // delay assertion of sync signal by the given number of cycles
        COUNT: begin
          delay_counter_brc <= delay_counter_brc - 1;
          if (delay_counter_brc == 0) begin
            state <= DONE;
            sync_int <= 1'b1;
          end
        end

        // issue done signal until the trigger is released
        DONE: begin
          sync_int <= 1'b0;
          pll_sync_done_brc <= 1'b1;
          if (pll_sync_trigger_brc == 0) begin
            state <= IDLE;
            pll_sync_done_brc <= 1'b0;
          end
        end

        // in case we run into an undefined state
        default: begin
          state <= IDLE;
        end
      endcase
    end
  end

  // transfer done signal back to ctrl_clk domain
  synchronizer #(
    .FALSE_PATH_TO_IN(1)
  ) done_sync (
    .clk(ctrl_clk), .rst(1'b0), .in(pll_sync_done_brc), .out(pll_sync_done)
  );

  //sync signal is captured at falling edge of clock to ensure hold time
  always @(negedge base_ref_clk) begin
    sync <= sync_int;
  end

  //------------------------------------------------------------------
  // PPS clock domain crossings
  //------------------------------------------------------------------
  // In the section below the PPS crosses multiple clock domains.
  // From the generation in BRC clock domain we transfer the signal over to
  // PRC using the aligned edge of the external LMK IC.
  // Afterwards we use the integer clock multiplier between PRC and RC to
  // get the PPS trigger to the radio clock domain.

  // BRC       --\____/----\____/----\____/----\____/----\____/----\____/
  // PRC       ___/---\___/---\___/---\___/---\___/---\___/---\___/---\__
  // RC        -\_/-\_/-\_/-\_/-\_/-\_/-\_/-\_/-\_/-\_/-\_/-\_/-\_/-\_/-\
  //                                      | aligned edge
  // PPS (BRC) __/--------------------------------------------------------
  // PPS (BRC delayed) ___________________/-------------------------------
  //   Has to shift PPS to start on aligned edge.
  //
  // PPS (PRC) __________________________________________/----------------
  //                                      |------------->| 2 PRC cycles
  //   2 stage synchronizer = 2 PRC cycle delay on aligned edge
  //
  // PPS (PRC delayed) __________/----------------------------------------
  //                                                     |------------------
  //   ------------------------->| up to PRC frequency cycles
  //   Shifts PPS pulse by up to 1 second (PPS period) to be present in the
  //   clock cycle before the aligned edge.
  //
  // PPS (RC)  ___________________________/-\_____________________________
  //                             |------->| RC clock multiplier based cycles
  //   Number of sync registers depends on clock multiplier between PRC and
  //   RC to align PPS signal with aligned edge. Additional logic to restore
  //   a one cycle long pulse from PPS signal with 25% duty cycle.

  //------------------------------------------------------------------
  // PPS delay (BRC domain)
  //------------------------------------------------------------------
  // this shift register delays the PPS trigger until the appearance of
  // the aligned edge of BRC and PRC
  // this delay has to encorporate the delay of the state machine above from
  // pps to sync output, the delay of the LMK chip from sync edge to aligned
  // edge and delay setting applied to the sync signal. Be sure to reduce the
  // number by 1 at the end to account for the final register.
  wire [7:0] pps_brc_delay_brc;
  synchronizer #(
    .FALSE_PATH_TO_IN(1),
    .WIDTH(8)
  ) pps_brc_delay_sync (
    .clk(base_ref_clk), .rst(1'b0), .in(pps_brc_delay), .out(pps_brc_delay_brc)
  );

  reg [255:0] pps_shift_reg_brc = 256'b0;
  reg         pps_delayed_brc = 1'b0;
  always @(posedge base_ref_clk) begin
    pps_shift_reg_brc <= {pps_shift_reg_brc[254:0], pps_brc};
    pps_delayed_brc <= pps_shift_reg_brc[pps_brc_delay_brc];
  end

  //------------------------------------------------------------------
  // PPS clock domain crossing
  //------------------------------------------------------------------
  // on the aligned edge of BRC and PRC this synchronizer is just a two stage
  // delay into the PRC domain as the edges occur at the same time
  // the tools should make sure we close timing on this edge
  wire pps_prc;
  synchronizer #(
    .FALSE_PATH_TO_IN(0)
  ) pps_delayed_brc_sync (
    .clk(pll_ref_clk), .rst(1'b0), .in(pps_delayed_brc), .out(pps_prc)
  );

  //------------------------------------------------------------------
  // PPS delay (PRC)
  //------------------------------------------------------------------
  // delay the PPS signal in PRC domain by a specifid amount to align with
  // other devices (max delay = 1 sec = next occurency of pps rising edge)
  // make sure that the initial count value accounts for the two stage
  // synchronizer from BRC to PRC, the final register upon counter reaches
  // its final value and it has to be one cycle earlier than the aligned edge
  // to get transferred to radio clock afterwards
  wire [25:0] pps_prc_delay_prc;
  synchronizer #(
    .FALSE_PATH_TO_IN(1),
    .WIDTH(26)
  ) pps_prc_delay_sync (
    .clk(pll_ref_clk), .rst(1'b0), .in(pps_prc_delay), .out(pps_prc_delay_prc)
  );

  //vhook_nowarn id=Misc11 msg={delay_counter_prc}
  reg [25:0] delay_counter_prc = 26'b0;
  reg        pps_delayed_prc = 1'b0;
  reg        pps_prc_delayed = 1'b0;
  always @(posedge pll_ref_clk) begin
    // disable delayed rising edge by default
    pps_delayed_prc <= 1'b0;
    pps_prc_delayed <= pps_prc;

    // reset counter on rising edge
    if (pps_prc & ~pps_prc_delayed) begin
      delay_counter_prc <= pps_prc_delay_prc;
    end
    else begin
      if (delay_counter_prc != 0) begin
        delay_counter_prc <= delay_counter_prc - 1;
      end
      if (delay_counter_prc == 1) begin
        pps_delayed_prc <= 1'b1;
      end
    end
  end

  //------------------------------------------------------------------
  // PPS PRC to radio clock
  //------------------------------------------------------------------
  // tiny shift register to account for the clock multiplier between prc and
  // rc. The divider has to account for the output register and the shift
  // register.
  wire [1:0] prc_rc_divider_rc;
  wire       pps_rc_enabled_rc;
  synchronizer #(
    .FALSE_PATH_TO_IN(1),
    .WIDTH(2)
  ) prc_rc_divider_sync (
    .clk(radio_clk), .rst(1'b0), .in(prc_rc_divider), .out(prc_rc_divider_rc)
  );
  synchronizer #(
    .FALSE_PATH_TO_IN(1)
  ) pps_rc_enabled_sync (
    .clk(radio_clk), .rst(1'b0), .in(pps_rc_enabled), .out(pps_rc_enabled_rc)
  );

  reg [3:0] pps_shift_reg_rc = 4'b0;
  always @(posedge radio_clk) begin
    pps_shift_reg_rc <= {pps_shift_reg_rc[2:0],  pps_delayed_prc};
    // Restoring a one clock cycle pulse by feeding back to output value.
    pps_out_rc <= pps_shift_reg_rc[prc_rc_divider_rc] & ~pps_out_rc & pps_rc_enabled_rc;
  end

  //------------------------------------------------------------------
  // debug assignment
  //------------------------------------------------------------------
  assign debug[0] = pps_delayed_brc;
  assign debug[1] = pps_delayed_prc;

endmodule