`timescale 1ns / 1ps
//////////////////////////////////////////////////////////////////////////////////
// Tage分支预测器，历史长度10，20，40，80
//////////////////////////////////////////////////////////////////////////////////


module TAGE(
    input clk,
    input rst,
    input pause,
    input recover,
    input new_branch_happen,
    input new_branch_taken,
    // For branch prediction
    input [31:0] br_pc,
    output pred_taken,
    output TAGEPred pred_info,
    // For branch prediction update
    input commit_valid,
    input [31:0] committed_pc,
    input TAGEPred committed_pred_info,
    input committed_branch_taken,
    input committed_mispred
    );
    
    TAGEIndex [3:0] index_01;
    TAGETag [3:0] PCTags_01;
    TAGEIndex [3:0] index_01_r;
    TAGETag [3:0] PCTags_01_r;
    wire flush_ubits_hi_01, flush_ubits_lo_01;
    TAGE_Phase0 phase0(
        .clk(clk),
        .rst(rst),
        .pause(pause),
        .recover(recover),
        .new_branch_happen(new_branch_happen),
        .new_branch_taken(new_branch_taken),
        .br_pc(br_pc),
        .commit_valid(commit_valid),
        .committed_branch_taken(committed_branch_taken),
        // Phase0 - Phase 1
        .index(index_01),
        .PCTags(PCTags_01),
        .flush_ubits_hi(flush_ubits_hi_01),
        .flush_ubits_lo(flush_ubits_lo_01)
    );

    // Phase 0/1 Regs
    always_ff @(posedge clk) begin
        if(rst) begin
            for(integer i=0;i<4;i++)    begin
                index_01_r[i] <= 0;
                PCTags_01_r[i] <= 0;
            end
        end else begin
            for(integer i=0;i<4;i++)    begin
                index_01_r[i] <= index_01[i];
                PCTags_01_r[i] <= PCTags_01[i];
            end
        end
    end

    // Phase 1/2 Regs
    TAGEPred TAGEResp_o, TAGEResp_r;
    wire PredTaken_o;
    reg PredTaken_r;
    TAGE_Phase1 phase1(
        .clk(clk),
        .rst(rst),
        .pause(pause),
        .recover(recover),
        // 是否需要Flush Useful Bit
        .flush_ubits_hi(flush_ubits_hi_01), 
        .flush_ubits_lo(flush_ubits_lo_01),
        // 访问Tage的四个Index
        .indexes(index_01_r),
        // For branch prediction
        .PCTags(PCTags_01_r),
        .TAGEResp(TAGEResp_o),
        .PredTaken(PredTaken_o),
        // For branch prediction update
        .committed_branch_taken(committed_branch_taken),
        .committed_pc(committed_branch_taken),
        .commit_valid(commit_valid),
        .committed_pred_info(committed_pred_info),
        .committed_mispred(committed_mispred)
    );

    always_ff @(posedge clk) begin
        if(rst) begin
            TAGEResp_r <= 0;
            PredTaken_r <= 0;
        end else begin
            TAGEResp_r  <= TAGEResp_o;
            PredTaken_r <= PredTaken_o;
        end 
    end

    assign pred_taken = PredTaken_r;
    assign pred_info = TAGEResp_r;
endmodule