// Copyright 2018 ETH Zurich and University of Bologna.
// Copyright and related rights are licensed under the Solderpad Hardware
// License, Version 0.51 (the "License"); you may not use this file except in
// compliance with the License.  You may obtain a copy of the License at
// http://solderpad.org/licenses/SHL-0.51. Unless required by applicable law
// or agreed to in writing, software, hardware and materials distributed under
// this License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR
// CONDITIONS OF ANY KIND, either express or implied. See the License for the
// specific language governing permissions and limitations under the License.
//
// Author: Stefan Mach, ETH Zurich
// Date: 12.04.2018
// Description: Wrapper for the floating-point unit


import ariane_pkg::*;

module fpu_wrap (
    input  logic                     clk_i,
    input  logic                     rst_ni,
    input  logic                     flush_i,
    input  logic [TRANS_ID_BITS-1:0] trans_id_i,
    input  fu_t                      fu_i,
    output logic                     fpu_ready_o,
    input  logic                     fpu_valid_i,
    input  fu_op                     operator_i,
    input  logic [FLEN-1:0]          operand_a_i,
    input  logic [FLEN-1:0]          operand_b_i,
    input  logic [FLEN-1:0]          operand_c_i,
    input  logic [1:0]               fpu_fmt_i,
    input  logic [2:0]               fpu_rm_i,
    input  logic [2:0]               fpu_frm_i,
    output logic [TRANS_ID_BITS-1:0] fpu_trans_id_o,
    output logic [FLEN-1:0]          result_o,
    output logic                     fpu_valid_o,
    output exception_t               fpu_exception_o
);

    //-----------------------------------
    // FPnew encoding from FPnew package
    //-----------------------------------
    localparam OPBITS  =  4;
    localparam FMTBITS =  3;
    localparam IFMTBITS = 2;

    integer OP_NUMBITS, FMT_NUMBITS, IFMT_NUMBITS;

    logic [OPBITS-1:0] OP_FMADD;
    logic [OPBITS-1:0] OP_FNMSUB;
    logic [OPBITS-1:0] OP_ADD;
    logic [OPBITS-1:0] OP_MUL;
    logic [OPBITS-1:0] OP_DIV;
    logic [OPBITS-1:0] OP_SQRT;
    logic [OPBITS-1:0] OP_SGNJ;
    logic [OPBITS-1:0] OP_MINMAX;
    logic [OPBITS-1:0] OP_CMP;
    logic [OPBITS-1:0] OP_CLASS;
    logic [OPBITS-1:0] OP_F2I;
    logic [OPBITS-1:0] OP_I2F;
    logic [OPBITS-1:0] OP_F2F;
    logic [OPBITS-1:0] OP_CPK;

    logic [FMTBITS-1:0] FMT_FP32;
    logic [FMTBITS-1:0] FMT_FP64;
    logic [FMTBITS-1:0] FMT_FP16;
    logic [FMTBITS-1:0] FMT_FP8;
    logic [FMTBITS-1:0] FMT_FP16ALT;
    logic [FMTBITS-1:0] FMT_CUST1;
    logic [FMTBITS-1:0] FMT_CUST2;
    logic [FMTBITS-1:0] FMT_CUST3;

    logic [IFMTBITS-1:0] IFMT_INT8;
    logic [IFMTBITS-1:0] IFMT_INT16;
    logic [IFMTBITS-1:0] IFMT_INT32;
    logic [IFMTBITS-1:0] IFMT_INT64;

    // bind the constants from the fpnew entity
    fpnew_pkg_constants i_fpnew_constants ( .* );

    // always_comb begin
    //     assert (OPBITS >= OP_NUMBITS) else $error("OPBITS is smaller than %0d", OP_NUMBITS);
    //     assert (FMTBITS >= FMT_NUMBITS) else $error("FMTBITS is smaller than %0d", FMT_NUMBITS);
    //     assert (IFMTBITS >= IFMT_NUMBITS) else $error("IFMTBITS is smaller than %0d", IFMT_NUMBITS);
    // end

    //-------------------------------------------------
    // Inputs to the FPU and protocol inversion buffer
    //-------------------------------------------------
    logic [FLEN-1:0]     operand_a_n,  operand_a_q,  operand_a;
    logic [FLEN-1:0]     operand_b_n,  operand_b_q,  operand_b;
    logic [FLEN-1:0]     operand_c_n,  operand_c_q,  operand_c;
    logic [OPBITS-1:0]   fpu_op_n,     fpu_op_q,     fpu_op;
    logic                fpu_op_mod_n, fpu_op_mod_q, fpu_op_mod;
    logic [FMTBITS-1:0]  fpu_fmt_n,    fpu_fmt_q,    fpu_fmt;
    logic [FMTBITS-1:0]  fpu_fmt2_n,   fpu_fmt2_q,   fpu_fmt2;
    logic [IFMTBITS-1:0] fpu_ifmt_n,   fpu_ifmt_q,   fpu_ifmt;
    logic [2:0]          fpu_rm_n,     fpu_rm_q,     fpu_rm;
    logic                fpu_vec_op_n, fpu_vec_op_q, fpu_vec_op;

    logic [TRANS_ID_BITS-1:0] fpu_tag_n, fpu_tag_q, fpu_tag;

    logic fpu_in_ready, reg_in_ready;
    logic fpu_in_valid, reg_in_valid;
    logic fpu_out_ready, reg_out_ready;
    logic fpu_out_valid, reg_out_valid;

    logic [4:0] fpu_status;


    // generate if (FP_PRESENT) begin : fpu_gen

        //-----------------------------
        // Translate inputs
        //-----------------------------

        always_comb begin : input_translation

            automatic logic vec_replication; // control honoring of replication flag

            // Default Values
            operand_a_n         = operand_a_i;
            operand_b_n         = operand_b_i;
            operand_c_n         = operand_c_i;
            fpu_op_n            = OP_SGNJ; // sign injection by default
            fpu_op_mod_n        = 1'b0;
            fpu_fmt_n           = FMT_FP32;
            fpu_fmt2_n          = FMT_FP32;
            fpu_ifmt_n          = IFMT_INT32;
            fpu_rm_n            = fpu_rm_i;
            fpu_vec_op_n        = fu_i == FPU_VEC;
            fpu_tag_n           = trans_id_i;
            vec_replication     = fpu_rm_i[0]; // replication bit is sent via rm field

            // Scalar Rounding Modes - some ops encode inside RM but use smaller range
            if (!(fpu_rm_i inside {[3'b000:3'b100]}))
                fpu_rm_n = fpu_frm_i;

            // Vectorial ops always consult FRM
            if (fpu_vec_op_n)
                fpu_rm_n = fpu_frm_i;

            // Formats
            unique case (fpu_fmt_i)
                // FP32
                2'b00 : fpu_fmt_n = FMT_FP32;
                // FP64 or FP16ALT (vectorial)
                2'b01 : fpu_fmt_n = fpu_vec_op_n ? FMT_FP16ALT : FMT_FP64;
                // FP16 or FP16ALT (scalar)
                2'b10 : begin
                   if (!fpu_vec_op_n && fpu_rm_i==3'b101)
                       fpu_fmt_n = FMT_FP16ALT;
                   else
                       fpu_fmt_n = FMT_FP16;
                end
                // FP8
                default : fpu_fmt_n = FMT_FP8;
            endcase


            // Operations (this can modify the rounding mode field!)
            case (operator_i)
                // Addition
                FADD      : fpu_op_n = OP_ADD;
                // Subtraction is modified ADD
                FSUB      : begin
                    fpu_op_n     = OP_ADD;
                    fpu_op_mod_n = 1'b1;
                end
                // Multiplication
                FMUL      : fpu_op_n = OP_MUL;
                // Division
                FDIV      : fpu_op_n = OP_DIV;
                // Min/Max - OP is encoded in rm (000-001)
                FMIN_MAX  : fpu_op_n = OP_MINMAX;
                // Square Root
                FSQRT     : fpu_op_n = OP_SQRT;
                // Fused Multiply Add
                FMADD     : fpu_op_n = OP_FMADD;
                // Fused Multiply Subtract is modified FMADD
                FMSUB     : begin
                    fpu_op_n     = OP_FMADD;
                    fpu_op_mod_n = 1'b1;
                end
                // Fused Negated Multiply Subtract
                FNMSUB    : fpu_op_n = OP_FNMSUB;
                // Fused Negated Multiply Add is modified FNMSUB
                FNMADD    : begin
                    fpu_op_n     = OP_FNMSUB;
                    fpu_op_mod_n = 1'b1;
                end
                // Float to Int Cast - Op encoded in lowest two imm bits or rm
                FCVT_F2I  : begin
                    fpu_op_n     = OP_F2I;
                    // Vectorial Ops encoded in rm (000-001)
                    if (fpu_vec_op_n) begin
                        fpu_op_mod_n      = fpu_rm_i[0];
                        vec_replication = 1'b0; // no replication, R bit used for op
                        unique case (fpu_fmt_i)
                            2'b00 : fpu_ifmt_n = IFMT_INT32;
                            2'b01,
                            2'b10 : fpu_ifmt_n = IFMT_INT16;
                            2'b11 : fpu_ifmt_n = IFMT_INT8;
                        endcase
                    // Scalar casts encoded in imm
                    end else begin
                        fpu_op_mod_n = operand_c_n[0];
                        if (operand_c_n[1])
                            fpu_ifmt_n = IFMT_INT64;
                        else
                            fpu_ifmt_n = IFMT_INT32;
                    end
                end
                // Int to Float Cast - Op encoded in lowest two imm bits or rm
                FCVT_I2F  : begin
                    fpu_op_n = OP_I2F;
                    // Vectorial Ops encoded in rm (000-001)
                    if (fpu_vec_op_n) begin
                        fpu_op_mod_n      = fpu_rm_i[0];
                        vec_replication = 1'b0; // no replication, R bit used for op
                        unique case (fpu_fmt_i)
                            2'b00 : fpu_ifmt_n = IFMT_INT32;
                            2'b01,
                            2'b10 : fpu_ifmt_n = IFMT_INT16;
                            2'b11 : fpu_ifmt_n = IFMT_INT8;
                        endcase
                    // Scalar casts encoded in imm
                    end else begin
                        fpu_op_mod_n = operand_c_n[0];
                        if (operand_c_n[1])
                            fpu_ifmt_n = IFMT_INT64;
                        else
                            fpu_ifmt_n = IFMT_INT32;
                    end
                end
                // Float to Float Cast - Source format encoded in lowest two/three imm bits
                FCVT_F2F  : begin
                    fpu_op_n = OP_F2F;
                    // Vectorial ops encoded in lowest two imm bits
                    if (fpu_vec_op_n) begin
                        vec_replication = 1'b0; // no replication for casts (not needed)
                        unique case (operand_c_n[1:0])
                            2'b00: fpu_fmt2_n = FMT_FP32;
                            2'b01: fpu_fmt2_n = FMT_FP16ALT;
                            2'b10: fpu_fmt2_n = FMT_FP16;
                            2'b11: fpu_fmt2_n = FMT_FP8;
                        endcase
                    // Scalar ops encoded in lowest three imm bits
                    end else begin
                        unique case (operand_c_n[2:0])
                            3'b000: fpu_fmt2_n = FMT_FP32;
                            3'b001: fpu_fmt2_n = FMT_FP64;
                            3'b010: fpu_fmt2_n = FMT_FP16;
                            3'b110: fpu_fmt2_n = FMT_FP16ALT;
                            3'b011: fpu_fmt2_n = FMT_FP8;
                        endcase
                    end
                end
                // Scalar Sign Injection - op encoded in rm (000-010)
                FSGNJ     : fpu_op_n = OP_SGNJ;
                // Move from FPR to GPR - mapped to NOP since no recoding
                FMV_F2X   : begin
                    fpu_op_n          = OP_SGNJ;
                    fpu_op_mod_n      = 1'b1; // no NaN-Boxing
                    operand_b_n       = operand_a_n;
                    vec_replication   = 1'b0; // no replication, we set second operand
                end
                // Move from GPR to FPR - mapped to NOP since no recoding
                FMV_X2F   : begin
                    fpu_op_n          = OP_SGNJ;
                    operand_b_n       = operand_a_n;
                    vec_replication   = 1'b0; // no replication, we set second operand
                end
                // Scalar Comparisons - op encoded in rm (000-010)
                FCMP      : fpu_op_n = OP_CMP;
                // Classification
                FCLASS    : fpu_op_n = OP_CLASS;
                // Vectorial Minimum - set up scalar encoding in rm
                VFMIN     : begin
                    fpu_op_n = OP_MINMAX;
                    fpu_rm_n = 3'b000; // min
                end
                // Vectorial Maximum - set up scalar encoding in rm
                VFMAX     : begin
                    fpu_op_n = OP_MINMAX;
                    fpu_rm_n = 3'b001; // max
                end
                // Vectorial Sign Injection - set up scalar encoding in rm
                VFSGNJ    : begin
                    fpu_op_n = OP_SGNJ;
                    fpu_rm_n = 3'b000; // sgnj
                end
                // Vectorial Negated Sign Injection - set up scalar encoding in rm
                VFSGNJN   : begin
                    fpu_op_n = OP_SGNJ;
                    fpu_rm_n = 3'b001; // sgnjn
                end
                // Vectorial Xored Sign Injection - set up scalar encoding in rm
                VFSGNJX   : begin
                    fpu_op_n = OP_SGNJ;
                    fpu_rm_n = 3'b010; // sgnjx
                end
                // Vectorial Equals - set up scalar encoding in rm
                VFEQ      : begin
                    fpu_op_n = OP_CMP;
                    fpu_rm_n = 3'b010; // eq
                end
                // Vectorial Not Equals - set up scalar encoding in rm
                VFNE      : begin
                    fpu_op_n     = OP_CMP;
                    fpu_op_mod_n = 1'b1;   // invert output
                    fpu_rm_n     = 3'b010; // eq
                    end
                // Vectorial Less Than - set up scalar encoding in rm
                VFLT      : begin
                    fpu_op_n = OP_CMP;
                    fpu_rm_n = 3'b001; // lt
                end
                // Vectorial Greater or Equal - set up scalar encoding in rm
                VFGE      : begin
                    fpu_op_n     = OP_CMP;
                    fpu_op_mod_n = 1'b1;   // invert output
                    fpu_rm_n     = 3'b001; // lt
                end
                // Vectorial Less or Equal - set up scalar encoding in rm
                VFLE      : begin
                    fpu_op_n = OP_CMP;
                    fpu_rm_n = 3'b000; // le
                end
                // Vectorial Greater Than - set up scalar encoding in rm
                VFGT      : begin
                    fpu_op_n     = OP_CMP;
                    fpu_op_mod_n = 1'b1;   // invert output
                    fpu_rm_n     = 3'b000; // le
                end

                // VFCPKAB_S :
                // VFCPKCD_S :
                // VFCPKAB_D :
                // VFCPKCD_D :

                // by default set opb = opa to have a sgnj nop
                default : operand_b_n = operand_a_n;
            endcase

            // Replication
            if (fpu_vec_op_n && vec_replication)
                case (fpu_fmt_n)
                    FMT_FP32    : operand_b_n = RVD ? {2{operand_b_n[31:0]}} : operand_b_n;
                    FMT_FP16,
                    FMT_FP16ALT : operand_b_n = RVD ? {4{operand_b_n[15:0]}} : {2{operand_b_n[15:0]}};
                    FMT_FP8     : operand_b_n = RVD ? {8{operand_b_n[7:0]}}  : {4{operand_b_n[7:0]}};
                endcase // fpu_fmt_n

            // Ugly but needs to be done: map additions to operands B and C
            if (fpu_op_n == OP_ADD) begin
                operand_c_n = operand_b_n;
                operand_b_n = operand_a_n;
            end

        end


        //---------------------------------------------------------
        // Upstream protocol inversion: InValid depends on InReady
        //---------------------------------------------------------

        // Input is ready whenever the register is free to accept a potentially spilling instruction
        assign fpu_ready_o = reg_in_ready;

        // Input data goes to the buffer register if the received instruction cannot be handled
        assign reg_in_valid = fpu_valid_i & ~fpu_in_ready;

        // Data being applied to unit is taken from the register if there's an instruction waiting
        assign fpu_in_valid = reg_out_valid | fpu_valid_i;

        // The input register is ready to accept new data if:
        // 1. The current instruction will be processed by the fpu
        // 2. There is no instruction waiting in the register
        assign reg_in_ready = reg_out_ready | ~reg_out_valid;

        // Register output side is signalled ready if:
        // 1. The operation held in the reg is valid and will be processed
        // 2. The register doesn't hold a valid instructin
        assign reg_out_ready = fpu_in_ready | ~reg_out_valid;

        // Buffer register
        always_ff @(posedge clk_i or negedge rst_ni) begin : fp_buffer_reg
            if(~rst_ni) begin
                reg_out_valid <= '0;
                operand_a_q   <= '0;
                operand_b_q   <= '0;
                operand_c_q   <= '0;
                fpu_op_q      <= '0;
                fpu_op_mod_q  <= '0;
                fpu_fmt_q     <= '0;
                fpu_fmt2_q    <= '0;
                fpu_ifmt_q    <= '0;
                fpu_rm_q      <= '0;
                fpu_vec_op_q  <= '0;
                fpu_tag_q     <= '0;
            end else begin
                if (reg_out_ready) begin // Only advance pipeline if unit is ready for our op
                    reg_out_valid <= reg_in_valid;
                    if (reg_in_valid) begin // clock gate data to save poer
                        operand_a_q   <= operand_a_n;
                        operand_b_q   <= operand_b_n;
                        operand_c_q   <= operand_c_n;
                        fpu_op_q      <= fpu_op_n;
                        fpu_op_mod_q  <= fpu_op_mod_n;
                        fpu_fmt_q     <= fpu_fmt_n;
                        fpu_fmt2_q    <= fpu_fmt2_n;
                        fpu_ifmt_q    <= fpu_ifmt_n;
                        fpu_rm_q      <= fpu_rm_n;
                        fpu_vec_op_q  <= fpu_vec_op_n;
                        fpu_tag_q     <= fpu_tag_n;
                    end
                end
            end
        end

        // Select FPU input data: from register if valid data in register, else directly vom input
        assign operand_a  = reg_out_valid ? operand_a_q  : operand_a_n;
        assign operand_b  = reg_out_valid ? operand_b_q  : operand_b_n;
        assign operand_c  = reg_out_valid ? operand_c_q  : operand_c_n;
        assign fpu_op     = reg_out_valid ? fpu_op_q     : fpu_op_n;
        assign fpu_op_mod = reg_out_valid ? fpu_op_mod_q : fpu_op_mod_n;
        assign fpu_fmt    = reg_out_valid ? fpu_fmt_q    : fpu_fmt_n;
        assign fpu_fmt2   = reg_out_valid ? fpu_fmt2_q   : fpu_fmt2_n;
        assign fpu_ifmt   = reg_out_valid ? fpu_ifmt_q   : fpu_ifmt_n;
        assign fpu_rm     = reg_out_valid ? fpu_rm_q     : fpu_rm_n;
        assign fpu_vec_op = reg_out_valid ? fpu_vec_op_q : fpu_vec_op_n;
        assign fpu_tag    = reg_out_valid ? fpu_tag_q    : fpu_tag_n;

        //---------------
        // FPU instance
        //---------------
        fpnew_top #(
            .WIDTH                ( FLEN          ),
            .TAG_WIDTH            ( TRANS_ID_BITS ),
            .RV64                 ( 1'b1          ),
            .RVF                  ( RVF           ),
            .RVD                  ( RVD           ),
            .Xf16                 ( XF16          ),
            .Xf16alt              ( XF16ALT       ),
            .Xf8                  ( XF8           ),
            .Xfvec                ( XFVEC         ),
            // TODO MOVE THESE VALUES TO PACKAGE
            .LATENCY_COMP_F       ( 31'h2         ),
            .LATENCY_COMP_D       ( 31'h3         ),
            .LATENCY_COMP_Xf16    ( 31'h2         ),
            .LATENCY_COMP_Xf16alt ( 31'h2         ),
            .LATENCY_COMP_Xf8     ( 31'h1         ),
            .LATENCY_DIVSQRT      ( 31'h1         ),
            .LATENCY_NONCOMP      ( 31'h0         ),
            .LATENCY_CONV         ( 31'h1         )
        ) fpnew_top_i (
            .Clk_CI         ( clk_i          ),
            .Reset_RBI      ( rst_ni         ),
            .A_DI           ( operand_a      ),
            .B_DI           ( operand_b      ),
            .C_DI           ( operand_c      ),
            .RoundMode_SI   ( fpu_rm         ),
            .Op_SI          ( fpu_op         ),
            .OpMod_SI       ( fpu_op_mod     ),
            .VectorialOp_SI ( fpu_vec_op     ),
            .FpFmt_SI       ( fpu_fmt        ),
            .FpFmt2_SI      ( fpu_fmt2       ),
            .IntFmt_SI      ( fpu_ifmt       ),
            .Tag_DI         ( fpu_tag        ),
            .InValid_SI     ( fpu_in_valid   ),
            .InReady_SO     ( fpu_in_ready   ),
            .Z_DO           ( result_o       ),
            .Status_DO      ( fpu_status     ),
            .Tag_DO         ( fpu_trans_id_o ),
            .OutValid_SO    ( fpu_out_valid  ),
            .OutReady_SI    ( fpu_out_ready  )
        );

        // Pack status flag into exception cause, tval ignored in wb, exception is always invalid
        assign fpu_exception_o.cause = {59'h0, fpu_status};
        assign fpu_exception_o.valid = 1'b0;

        // Donwstream write port is dedicated to FPU and always ready
        assign fpu_out_ready = 1'b1;

        // Downstream valid from unit
        assign fpu_valid_o = fpu_out_valid;

    // end else begin : no_fpu_gen

    //     assign fpu_ready_o     = 1'b0;
    //     assign fpu_trans_id_o  = '0;
    //     assign result_o        = '0;
    //     assign fpu_valid_o     = 1'b0;
    //     assign fpu_exception_o = '0;
    // end
    // endgenerate

endmodule
