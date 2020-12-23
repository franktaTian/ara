// Copyright 2020 ETH Zurich and University of Bologna.
// Copyright and related rights are licensed under the Solderpad Hardware
// License, Version 0.51 (the "License"); you may not use this file except in
// compliance with the License.  You may obtain a copy of the License at
// http://solderpad.org/licenses/SHL-0.51. Unless required by applicable law
// or agreed to in writing, software, hardware and materials distributed under
// this License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR
// CONDITIONS OF ANY KIND, either express or implied. See the License for the
// specific language governing permissions and limitations under the License.
//
// File:   masku.sv
// Author: Matheus Cavalcante <matheusd@iis.ee.ethz.ch>
// Date:   17.12.2020
//
// Copyright (C) 2020 ETH Zurich, University of Bologna
// All rights reserved.
//
// Description:
// This is Ara's mask unit. It fetches operands from any one the lanes, and
// then sends back to them whether the elements are predicated or not.
// This unit is shared between all the functional units who can execute
// predicated instructions.

module masku import ara_pkg::*; import rvv_pkg::*; #(
    parameter int  unsigned NrLanes   = 0,
    parameter type          vaddr_t   = logic,                // Type used to address vector register file elements
    // Dependant parameters. DO NOT CHANGE!
    parameter int  unsigned DataWidth = $bits(elen_t),        // Width of the lane datapath
    parameter int  unsigned StrbWidth = DataWidth/8,
    parameter type          strb_t    = logic [StrbWidth-1:0] // Byte-strobe type
  ) (
    input  logic                   clk_i,
    input  logic                   rst_ni,
    // Interface with the main sequencer
    input  pe_req_t                pe_req_i,
    input  logic                   pe_req_valid_i,
    output logic                   pe_req_ready_o,
    output pe_resp_t               pe_resp_o,
    // Interface with the lanes' vector register file
    input  elen_t    [NrLanes-1:0] masku_operand_i,
    input  logic     [NrLanes-1:0] masku_operand_valid_i,
    output logic     [NrLanes-1:0] masku_operand_ready_o,
    // Interface with the VFUs
    output strb_t    [NrLanes-1:0] mask_o,
    output logic     [NrLanes-1:0] mask_valid_o,
    input  logic     [NrLanes-1:0] lane_mask_ready_i,
    input  logic                   vldu_mask_ready_i,
    input  logic                   vstu_mask_ready_i
  );

  import cf_math_pkg::idx_width;

  /******************************
   *  Vector instruction queue  *
   ******************************/

  // We store a certain number of in-flight vector instructions.
  // To avoid any hazards between masked vector instructions, the mask
  // unit is only capable of handling one vector instruction at a time.
  // Optimizing this unit is left as future work.

  localparam VInsnQueueDepth = 1;

  struct packed {
    pe_req_t [VInsnQueueDepth-1:0] vinsn;

    // We also need to count how many instructions are queueing to be
    // issued/committed, to avoid accepting more instructions than
    // we can handle.
    logic [idx_width(VInsnQueueDepth)-1:0] issue_cnt;
    logic [idx_width(VInsnQueueDepth)-1:0] commit_cnt;
  } vinsn_queue_d, vinsn_queue_q;

  // Is the vector instruction queue full?
  logic vinsn_queue_full;
  assign vinsn_queue_full = (vinsn_queue_q.commit_cnt == VInsnQueueDepth);

  // Do we have a vector instruction ready to be issued?
  pe_req_t vinsn_issue;
  logic    vinsn_issue_valid;
  assign vinsn_issue       = vinsn_queue_q.vinsn[0];
  assign vinsn_issue_valid = (vinsn_queue_q.issue_cnt != '0);

  // Do we have a vector instruction with results being committed?
  pe_req_t vinsn_commit;
  logic    vinsn_commit_valid;
  assign vinsn_commit       = vinsn_queue_q.vinsn[0];
  assign vinsn_commit_valid = (vinsn_queue_q.commit_cnt != '0);

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      vinsn_queue_q <= '0;
    end else begin
      vinsn_queue_q <= vinsn_queue_d;
    end
  end

  /*******************
   *  Result queues  *
   *******************/

  localparam int unsigned ResultQueueDepth = 2;

  // There is a result queue per lane, holding the operands that were not
  // yet used by the corresponding lane.

  // Result queue
  strb_t [ResultQueueDepth-1:0][NrLanes-1:0] result_queue_d, result_queue_q;
  logic  [ResultQueueDepth-1:0][NrLanes-1:0] result_queue_valid_d, result_queue_valid_q;
  // We need two pointers in the result queue. One pointer to
  // indicate with `payload_t` we are currently writing into (write_pnt),
  // and one pointer to indicate which `payload_t` we are currently
  // reading from and writing into the lanes (read_pnt).
  logic  [idx_width(ResultQueueDepth)-1:0]   result_queue_write_pnt_d, result_queue_write_pnt_q;
  logic  [idx_width(ResultQueueDepth)-1:0]   result_queue_read_pnt_d, result_queue_read_pnt_q;
  // We need to count how many valid elements are there in this result queue.
  logic  [idx_width(ResultQueueDepth):0]     result_queue_cnt_d, result_queue_cnt_q;

  // Is the result queue full?
  logic result_queue_full;
  assign result_queue_full = (result_queue_cnt_q == ResultQueueDepth);
  // Is the result queue empty?
  logic result_queue_empty;
  assign result_queue_empty = (result_queue_cnt_q == '0);

  always_ff @(posedge clk_i or negedge rst_ni) begin: p_result_queue_ff
    if (!rst_ni) begin
      result_queue_q           <= '0;
      result_queue_valid_q     <= '0;
      result_queue_write_pnt_q <= '0;
      result_queue_read_pnt_q  <= '0;
      result_queue_cnt_q       <= '0;
    end else begin
      result_queue_q           <= result_queue_d;
      result_queue_valid_q     <= result_queue_valid_d;
      result_queue_write_pnt_q <= result_queue_write_pnt_d;
      result_queue_read_pnt_q  <= result_queue_read_pnt_d;
      result_queue_cnt_q       <= result_queue_cnt_d;
    end
  end

  /***************
   *  Mask unit  *
   ***************/

  // Vector instructions currently running
  logic [NrVInsn-1:0] vinsn_running_d, vinsn_running_q;

  // Interface with the main sequencer
  pe_resp_t pe_resp;

  // Remaining elements of the current instruction in the issue phase
  vlen_t issue_cnt_d, issue_cnt_q;
  // Remaining elements of the current instruction in the commit phase
  vlen_t commit_cnt_d, commit_cnt_q;

  // Pointers
  //
  // We need a pointer to which byte in the full VRF word we are writing mask data into.
  logic [idx_width(StrbWidth*NrLanes):0] vrf_pnt_d, vrf_pnt_q;

  always_comb begin: p_masku
    // Maintain state
    vinsn_queue_d = vinsn_queue_q;
    issue_cnt_d   = issue_cnt_q;
    commit_cnt_d  = commit_cnt_q;

    vrf_pnt_d = vrf_pnt_q;

    result_queue_d           = result_queue_q;
    result_queue_valid_d     = result_queue_valid_q;
    result_queue_write_pnt_d = result_queue_write_pnt_q;
    result_queue_read_pnt_d  = result_queue_read_pnt_q;
    result_queue_cnt_d       = result_queue_cnt_q;

    // Vector instructions currently running
    vinsn_running_d = vinsn_running_q & pe_req_i.vinsn_running;

    // We are not ready, by default
    pe_resp               = '0;
    masku_operand_ready_o = 1'b0;

    // Inform the main sequencer if we are idle
    pe_req_ready_o = !vinsn_queue_full;

    // By default, send no operands
    mask_o       = '0;
    mask_valid_o = '0;

    /******************************
     *  Read data from the lanes  *
     ******************************/

    // We are ready to read mask data from the lanes if all the following are respected:
    // - There is an instruction ready to be issued.
    // - There are operands from the lanes available.
    // - There is place in the result queue to write the mask data read from the lanes
    if (vinsn_issue_valid && &masku_operand_valid_i && !result_queue_full) begin
      // Copy data from the mask operands into the result queue
      for (int mask_byte = 0; mask_byte < NrLanes*StrbWidth; mask_byte++) begin
        // Map mask_byte to the corresponding byte in the VRF word (sequential)
        automatic int vrf_seq_byte = mask_byte + vrf_pnt_q;
        // And then shuffle it
        automatic int vrf_byte     = shuffle_index(vrf_seq_byte, NrLanes, vinsn_issue.vtype.vsew);

        // At which lane, and what is the byte offset in that lane, of the byte vrf_byte?
        automatic int vrf_lane   = vrf_byte >> 3;
        automatic int vrf_offset = vrf_byte[2:0];

        // A single bit from the mask operands can be used several times, depending on the vsew.
        automatic int mask_seq_byte = vrf_seq_byte >> (int'(EW64) - int'(vinsn_issue.vtype.vsew));

        // At which lane, and what is the byte offset in that lane, of the mask operand from vrf_seq_byte?
        automatic int mask_lane   = mask_seq_byte >> 3;
        automatic int mask_offset = mask_seq_byte[2:0];

        // Copy the mask operand
        result_queue_d[result_queue_write_pnt_q][vrf_lane][vrf_offset] = masku_operand_i[mask_byte >> 3][mask_byte[2:0]];
      end

      // Account for the used operands
      vrf_pnt_d += NrLanes * (1 << (int'(EW64) - vinsn_issue.vtype.vsew));

      // Increment result queue pointers and counters
      result_queue_cnt_d += 1;
      if (result_queue_cnt_q == ResultQueueDepth-1)
        result_queue_cnt_d = '0;
      else
        result_queue_write_pnt_d += 1;

      // Trigger the request signal
      result_queue_valid_d[result_queue_write_pnt_q] = {NrLanes{1'b1}};

      // Account for the results that were issued
      issue_cnt_d = issue_cnt_q - NrLanes * (8 << (int'(EW64) - vinsn_issue.vtype.vsew));
      if (issue_cnt_q < NrLanes * (8 << (int'(EW64) - vinsn_issue.vtype.vsew)))
        issue_cnt_d = '0;

      // Consumed all valid bytes in this R beat
      if (vrf_pnt_d == NrLanes*8 || issue_cnt_d == '0) begin
        // Request another beat
        masku_operand_ready_o = '1;
        // Reset the pointer
        vrf_pnt_d             = '0;
      end
    end

    // Finished issuing results
    if (vinsn_issue_valid && issue_cnt_d == '0) begin
      // Increment vector instruction queue pointers and counters
      vinsn_queue_d.issue_cnt -= 1;
    end

    /*******************************
     *  Send operands to the VFUs  *
     *******************************/

    for (int lane = 0; lane < NrLanes; lane++) begin: send_operand
      mask_valid_o[lane] = result_queue_valid_q[result_queue_read_pnt_q][lane];
      mask_o[lane]       = result_queue_q[result_queue_read_pnt_q][lane];
      // Received a grant from the VFUs.
      // The VLDU and the VSTU acknowledge all the operands at once.
      // Deactivate the request, but do not bump the pointers for now.
      if (lane_mask_ready_i[lane] || vldu_mask_ready_i || vstu_mask_ready_i) begin
        result_queue_valid_d[result_queue_read_pnt_q][lane] = 1'b0;
        result_queue_d[result_queue_read_pnt_q][lane]       = '0;
      end
    end: send_operand

    // All lanes accepted the VRF request
    if (!(|result_queue_valid_d[result_queue_read_pnt_q]))
      // There is something waiting to be written
      if (!result_queue_empty) begin
        // Increment the read pointer
        if (result_queue_read_pnt_q == ResultQueueDepth-1)
          result_queue_read_pnt_d = 0;
        else
          result_queue_read_pnt_d = result_queue_read_pnt_q + 1;

        // Decrement the counter of results waiting to be written
        result_queue_cnt_d -= 1;

        // Decrement the counter of remaining vector elements waiting to be written
        commit_cnt_d = commit_cnt_q - NrLanes * (8 << (int'(EW64) - vinsn_commit.vtype.vsew));
        if (commit_cnt_q < (NrLanes * (8 << (int'(EW64) - vinsn_commit.vtype.vsew))))
          commit_cnt_d = '0;
      end

    // Finished committing the results of a vector instruction
    if (vinsn_commit_valid && commit_cnt_d == '0) begin
      // Mark the vector instruction as being done
      pe_resp.vinsn_done[vinsn_commit.id] = 1'b1;

      // Update the commit counters and pointers
      vinsn_queue_d.commit_cnt -= 1;
    end

    /****************************
     *  Accept new instruction  *
     ****************************/

    if (!vinsn_queue_full && pe_req_valid_i && !vinsn_running_q[pe_req_i.id] && !pe_req_i.vm) begin
      vinsn_queue_d.vinsn[0]       = pe_req_i;
      vinsn_running_d[pe_req_i.id] = 1'b1;

      // Unused fields
      vinsn_queue_d.vinsn[0].vs1           = '0;
      vinsn_queue_d.vinsn[0].use_vs1       = '0;
      vinsn_queue_d.vinsn[0].vs2           = '0;
      vinsn_queue_d.vinsn[0].use_vs2       = '0;
      vinsn_queue_d.vinsn[0].scalar_op     = '0;
      vinsn_queue_d.vinsn[0].use_scalar_op = '0;
      vinsn_queue_d.vinsn[0].stride        = '0;
      vinsn_queue_d.vinsn[0].vinsn_running = '0;
      vinsn_queue_d.vinsn[0].hazard_vs1    = '0;
      vinsn_queue_d.vinsn[0].hazard_vs2    = '0;
      vinsn_queue_d.vinsn[0].hazard_vm     = '0;
      vinsn_queue_d.vinsn[0].hazard_vd     = '0;

      // Initialize counters
      if (vinsn_queue_d.issue_cnt == '0)
        issue_cnt_d = pe_req_i.vl;
      if (vinsn_queue_d.commit_cnt == '0)
        commit_cnt_d = pe_req_i.vl;

      // Bump pointers and counters of the vector instruction queue
      vinsn_queue_d.issue_cnt += 1;
      vinsn_queue_d.commit_cnt += 1;
    end
  end: p_masku

  always_ff @(posedge clk_i or negedge rst_ni) begin
    if (!rst_ni) begin
      vinsn_running_q <= '0;
      issue_cnt_q     <= '0;
      commit_cnt_q    <= '0;
      vrf_pnt_q       <= '0;
      pe_resp_o       <= '0;
    end else begin
      vinsn_running_q <= vinsn_running_d;
      issue_cnt_q     <= issue_cnt_d;
      commit_cnt_q    <= commit_cnt_d;
      vrf_pnt_q       <= vrf_pnt_d;
      pe_resp_o       <= pe_resp;
    end
  end

endmodule : masku
