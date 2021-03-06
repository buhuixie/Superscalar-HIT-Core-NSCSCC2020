`timescale 1ns / 1ps
`include "../defines/defines.svh"
`include "../defs.sv"
module ALU(
    input UOPBundle uops,       // 输入的微操作
    input PRFrData rdata,       // 寄存器读入的数据
    input PRFwInfo bypass_alu0, bypass_alu1,  // 从下一级和下面的ALU旁路回来
    CP0WRInterface.req  alu_cp0,
    output PRFwInfo wbData,     // 计算回写的数据
    output UOPBundle uops_o,              // 传递给下一级的
    FU_ROB.fu   alu_rob
    );
wire overflow;
logic j2BadVaddr;
wire [31:0] ALUPC = uops.pc;
wire ALU_Valid = uops.valid;
// trigger on taken bad jump addr. If error is a ExcAddressErrIF, SET BOTH EPC AND BADVADDR TO BADVADDR
assign j2BadVaddr = alu_rob.setBranchStatus &&  alu_rob.branchTaken && (|alu_rob.branchAddr[1:0]);
assign alu_rob.setFinish = uops.valid;
assign alu_rob.id = uops.id;
assign alu_rob.setException = uops.valid && (j2BadVaddr || (!uops.causeExc && overflow));
assign alu_rob.exceptionType = j2BadVaddr ? ExcAddressErrIF : ExcIntOverflow;
// 取指不对齐异常，优先级最高
assign alu_rob.BadVAddr    = alu_rob.branchAddr;


// Result Select

// 分支指令结果
Word branch_target;
Word move_res;
Word arithmetic_res;
Word branch_res;
Word logic_res;
Word shift_res;
Word cp0_res;
Word clz_res;
Word clo_res;
Word count_res;
wire bypass_alu0_src0_en = bypass_alu0.wen && (bypass_alu0.rd == uops.op0PAddr);
wire bypass_alu0_src1_en = bypass_alu0.wen && (bypass_alu0.rd == uops.op1PAddr);
wire bypass_alu1_src0_en = bypass_alu1.wen && (bypass_alu1.rd == uops.op0PAddr);
wire bypass_alu1_src1_en = bypass_alu1.wen && (bypass_alu1.rd == uops.op1PAddr);

Word src0, src1;
assign src0 = uops.op0re ?  ( bypass_alu0_src0_en ? bypass_alu0.wdata : 
                            ( bypass_alu1_src0_en ? bypass_alu1.wdata : rdata.rs0_data ) ) : rdata.rs0_data;
assign src1 = uops.op1re ?  ( bypass_alu0_src1_en ? bypass_alu0.wdata : 
                            ( bypass_alu1_src1_en ? bypass_alu1.wdata : rdata.rs1_data ) ) : uops.imm ;

uOP uop;
assign uop = uops.uOP;
// ADEL, Break和Syscall在前面处理了
// What about JR into bad vaddr?
always_comb begin
    uops_o = uops;
    uops_o.branchAddr = branch_target;
    uops_o.branchTaken = branch_taken && uops.valid;
    uops_o.causeExc = uops.causeExc | overflow;
    uops_o.exception = uops.exception;
    if(!uops.causeExc || overflow ) begin    // 如果之前已经有异常
        if( uops.exception == ExcAddressErrL    || 
            uops.exception == ExcReservedInst   || 
            uops.exception == ExcEret ) begin      // 优先级更高的异常
            uops_o.exception = uops.exception;
        end else begin
            uops_o.exception = ExcIntOverflow;
        end
    end
end


// 逻辑运算结果
assign logic_res =  ( uop == OR_U   || uop == ORI_U || uop == LUI_U )   ? src0 | src1       :
                    ( uop == AND_U  || uop == ANDI_U )                  ? src0 & src1       :
                    ( uop == NOR_U )                                    ? ~(src0 | src1)    :
                    ( uop == XOR_U  || uop == XORI_U )                  ? src0 ^ src1       : 32'b0;

// 移位运算结果
assign shift_res =  ( uop == SLL_U || uop == SLLV_U ) ? src0 << src1[4:0] :
                    ( uop == SRL_U || uop == SRLV_U ) ? src0 >> src1[4:0] :
                    ( uop == SRA_U || uop == SRAV_U ) ? 
                    ( {32{src0[31]}} << (6'd32 - {1'b0, src1[4:0]}) ) | src0 >> src1[4:0] : 32'b0;

// 算术运算结果
wire [31:0] src1_complement;
wire [31:0] sum;
assign src1_complement = ( uop == SUB_U || uop == SUBU_U || uop == SLT_U || uop == SLTI_U ) ? ( ~src1 + 1'b1 ) : src1;
assign sum = src0 + src1_complement;
assign src0_lt_src1 =   ( uop == SLT_U || uop == SLTI_U ) ? // Signed compare
                        ( (src0[31] & !src1[31]) | 
                        ( !src0[31] & !src1[31] & sum[31]) | 
                        ( src0[31] & src1[31] & sum[31]) ) : 
                        ( src0 < src1 );                    // Unsigned Compare

assign arithmetic_res = ( uop == SLT_U || uop == SLTI_U || uop == SLTU_U || uop == SLTIU_U ) ? 
                        src0_lt_src1 : sum;
                        

// 移动指令结果
assign move_res = src0; // HILO寄存器被重命名，无论是MF还是MT，都是第一个操作数

// Word branch_target;
assign branch_taken =   ( uop == BEQ_U ) ? ( src0 == src1 ) :
                        ( uop == BNE_U ) ? ( src0 != src1 ) :
                        ( uop == BGEZ_U || uop == BGEZAL_U ) ? ( ~src0[31] ):
                        ( uop == BGTZ_U ) ? ( ~src0[31] & (|src0[30:0]) ) :
                        ( uop == BLEZ_U ) ? ~( ~src0[31] & (|src0[30:0]) ) :
                        ( uop == BLTZ_U || uop == BLTZAL_U ) ? ( src0[31] ) : 
                        ( uop == J_U || uop == JAL_U || uop == JR_U || uop == JALR_U ) ? 1 : 0;
assign branch_target = ( uop == JR_U || uop == JALR_U ) ? src0 : uops.predAddr;

// CP0指令结果
// CP0 interface  
/*

    logic [`CP0ADDR]    addr;
    logic [`CP0SEL]     sel;
    logic [31:0]        readData;
    logic [31:0]        writeData;
    logic               writeEn;

    // uopbundle
    logic   [4:0]           cp0Addr;
    logic   [31:0]          cp0Data;
    logic   [2:0]           cp0Sel;
*/
assign alu_cp0.addr         = uops.cp0Addr;
assign alu_cp0.sel          = uops.cp0Sel;
assign alu_cp0.writeEn      = (uop == MTC0_U);
assign alu_cp0.writeData    = src0;
assign cp0_res              = alu_cp0.readData;

assign alu_rob.setBranchStatus = uops.valid && uops.branchType != typeNormal;
assign alu_rob.branchAddr = branch_target;
assign alu_rob.branchTaken = branch_taken;

// ADEL, Break和Syscall在前面处理了

always_comb begin
    clo_res = 0;
    casex(src0)
        32'b0???????????????????????????????: clo_res = 32'd0;
        32'b10??????????????????????????????: clo_res = 32'd1;
        32'b110?????????????????????????????: clo_res = 32'd2;
        32'b1110????????????????????????????: clo_res = 32'd3;
        32'b11110???????????????????????????: clo_res = 32'd4;
        32'b111110??????????????????????????: clo_res = 32'd5;
        32'b1111110?????????????????????????: clo_res = 32'd6;
        32'b11111110????????????????????????: clo_res = 32'd7;
        32'b111111110???????????????????????: clo_res = 32'd8;
        32'b1111111110??????????????????????: clo_res = 32'd9;
        32'b11111111110?????????????????????: clo_res = 32'd10;
        32'b111111111110????????????????????: clo_res = 32'd11;
        32'b1111111111110???????????????????: clo_res = 32'd12;
        32'b11111111111110??????????????????: clo_res = 32'd13;
        32'b111111111111110?????????????????: clo_res = 32'd14;
        32'b1111111111111110????????????????: clo_res = 32'd15;
        32'b11111111111111110???????????????: clo_res = 32'd16;
        32'b111111111111111110??????????????: clo_res = 32'd17;
        32'b1111111111111111110?????????????: clo_res = 32'd18;
        32'b11111111111111111110????????????: clo_res = 32'd19;
        32'b111111111111111111110???????????: clo_res = 32'd20;
        32'b1111111111111111111110??????????: clo_res = 32'd21;
        32'b11111111111111111111110?????????: clo_res = 32'd22;
        32'b111111111111111111111110????????: clo_res = 32'd23;
        32'b1111111111111111111111110???????: clo_res = 32'd24;
        32'b11111111111111111111111110??????: clo_res = 32'd25;
        32'b111111111111111111111111110?????: clo_res = 32'd26;
        32'b1111111111111111111111111110????: clo_res = 32'd27;
        32'b11111111111111111111111111110???: clo_res = 32'd28;
        32'b111111111111111111111111111110??: clo_res = 32'd29;
        32'b1111111111111111111111111111110?: clo_res = 32'd30;
        32'b11111111111111111111111111111110: clo_res = 32'd31;
        32'b11111111111111111111111111111111: clo_res = 32'd32;
    endcase
end

always_comb begin
    clz_res = 0;
    casex(src0)
        32'b1???????????????????????????????: clz_res = 32'd0;
        32'b01??????????????????????????????: clz_res = 32'd1;
        32'b001?????????????????????????????: clz_res = 32'd2;
        32'b0001????????????????????????????: clz_res = 32'd3;
        32'b00001???????????????????????????: clz_res = 32'd4;
        32'b000001??????????????????????????: clz_res = 32'd5;
        32'b0000001?????????????????????????: clz_res = 32'd6;
        32'b00000001????????????????????????: clz_res = 32'd7;
        32'b000000001???????????????????????: clz_res = 32'd8;
        32'b0000000001??????????????????????: clz_res = 32'd9;
        32'b00000000001?????????????????????: clz_res = 32'd10;
        32'b000000000001????????????????????: clz_res = 32'd11;
        32'b0000000000001???????????????????: clz_res = 32'd12;
        32'b00000000000001??????????????????: clz_res = 32'd13;
        32'b000000000000001?????????????????: clz_res = 32'd14;
        32'b0000000000000001????????????????: clz_res = 32'd15;
        32'b00000000000000001???????????????: clz_res = 32'd16;
        32'b000000000000000001??????????????: clz_res = 32'd17;
        32'b0000000000000000001?????????????: clz_res = 32'd18;
        32'b00000000000000000001????????????: clz_res = 32'd19;
        32'b000000000000000000001???????????: clz_res = 32'd20;
        32'b0000000000000000000001??????????: clz_res = 32'd21;
        32'b00000000000000000000001?????????: clz_res = 32'd22;
        32'b000000000000000000000001????????: clz_res = 32'd23;
        32'b0000000000000000000000001???????: clz_res = 32'd24;
        32'b00000000000000000000000001??????: clz_res = 32'd25;
        32'b000000000000000000000000001?????: clz_res = 32'd26;
        32'b0000000000000000000000000001????: clz_res = 32'd27;
        32'b00000000000000000000000000001???: clz_res = 32'd28;
        32'b000000000000000000000000000001??: clz_res = 32'd29;
        32'b0000000000000000000000000000001?: clz_res = 32'd30;
        32'b00000000000000000000000000000001: clz_res = 32'd31;
        32'b00000000000000000000000000000000: clz_res = 32'd32;
    endcase
end

assign count_res = uop == CLZ_U ? clz_res : clo_res;

// 溢出的检查
assign overflow =   ( (!src0[31] & !src1_complement[31] & sum[31]) | 
                    ( src0[31] & src1_complement[31] & !sum[31]) ) & 
                    ( ( uop == ADD_U ) || ( uop == ADDI_U ) || ( uop == SUB_U ) ) ? 
                    1'b1 : 1'b0; 


ALUType alutype;
assign alutype = uops.aluType;

assign branch_res = uops.pc + 8;

// 结果赋值
assign wbData.rd = uops.dstPAddr;
assign wbData.wen = uops.dstwe & uops.valid;
assign wbData.wdata =   ( alutype == ALU_LOGIC  ) ? logic_res       :
                        ( alutype == ALU_SHIFT  ) ? shift_res       :
                        ( alutype == ALU_ARITH  ) ? arithmetic_res  :
                        ( alutype == ALU_MOVE   ) ? move_res        :
                        ( alutype == ALU_COUNT  ) ? count_res       :
                        ( alutype == ALU_BRANCH ) ? branch_res      : 
                        ( alutype == ALU_CP0    ) ? cp0_res         : 32'b0;


endmodule
