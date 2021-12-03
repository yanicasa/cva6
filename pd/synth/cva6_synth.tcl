#
# Copyright 2021 Thales DIS design services SAS
#
# Licensed under the Solderpad Hardware Licence, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.0
# You may obtain a copy of the License at https://solderpad.org/licenses/
#
# Original Author: Jean-Roch COULON (jean-roch.coulon@thalesgroup.com)
#

source -echo -verbose scripts/dc_setup.tcl

set clk_name main_clk
set clk_port clk_i
set rst_port rst_ni

set clk_ports_list [list $clk_port]
set clk_period $PERIOD
set gen_constraints $SET_CUSTOM_CONSTRAINTS
set_app_var search_path "../../core/fpu/src/common_cells/include/ $search_path"

sh rm -rf work
sh mkdir work
define_design_lib ariane_lib -path work

set CVA6_REPO_DIR "../.."
source Flist.cva6_synth

elaborate ${DESIGN_NAME} -library ariane_lib

uniquify
link

#clock definition
create_clock [get_ports $clk_port] -name $clk_name -period $clk_period

if {$gen_constraints == 1} {
    #10% clock uncertainty
    set_clock_uncertainty [expr 0.1*$clk_period] [get_clocks $clk_name]
}


#set_dont_touch to keep sram as black boxes
set_dont_touch i_cache_subsystem/i_wt_dcache/i_wt_dcache_mem/gen_tag_srams[*].i_tag_sram
set_dont_touch i_cache_subsystem/i_wt_dcache/i_wt_dcache_mem/gen_data_banks[*].i_data_sram
set_dont_touch i_cache_subsystem/i_cva6_icache/gen_sram[*].data_sram
set_dont_touch i_cache_subsystem/i_cva6_icache/gen_sram[*].tag_sram

if {$gen_constraints == 1} {
    # Virtual clocks to constraints input and output ports
    create_clock -name virtual_clkin_1 -period $clk_period 
    create_clock -name virtual_clkin_2 -period $clk_period 
    create_clock -name virtual_clkout_1 -period $clk_period 
    create_clock -name virtual_clkout_2 -period $clk_period 
    
    set_clock_uncertainty [expr 0.1*$clk_period] [get_clocks virtual*]
    
    # Clock groups (used to constraints correctly feedthrough path)
    set_clock_groups -logically_exclusive \
                     -group {virtual_clkin_1 clk virtual_clkout_1} \
                     -group {virtual_clkin_2 virtual_clkout_2}
    
    set_clock_groups -logically_exclusive \
                     -group {virtual_clkin_1} \
                     -group {virtual_clkout_1}
    
    # 80 20 on all input/output port except clk
    set_output_delay -clock virtual_clkout_1 -max [expr 0.8*$clk_period] [get_ports -filter "direction==out" *]
    set_input_delay -clock virtual_clkin_1 -max [expr 0.8*$clk_period] [get_ports -filter "direction==in && full_name != ${clk_port}" *]
    
    # 40 60 on all input/output feedthrough port except clk
    set_output_delay -clock virtual_clkout_2 -max [expr 0.4*$clk_period] [get_ports -filter "direction==out" *] -add
    set_input_delay -clock virtual_clkin_2 -max [expr 0.4*$clk_period] [get_ports -filter "direction==in && full_name != ${clk_port}" *] -add
}

#scan evaluation
create_port scan_en
create_port scan_in
create_port scan_out -direction out
set_dft_signal -view existing \
               -type ScanClock \
               -timing [list 20.2 40.4] \
               -port $clk_port
set_dft_signal -view existing \
               -type Reset \
               -port $rst_port \
               -active_state 0
set_dft_signal -view spec \
               -type ScanEnable \
               -port scan_en \
               -active_state 1 
set_dft_signal -view spec \
               -type ScanDataOut \
               -port scan_out
set_dft_signal -view spec \
               -type ScanDataIn \
               -port scan_in

write -hierarchy -format ddc -output ${DCRM_ELABORATED_DESIGN_DDC_OUTPUT_FILE}

change_name -rule verilog -hier

# Prevent assignment statements in the Verilog netlist.
set_fix_multiple_port_nets -all -buffer_constants

#constraint the timing to and from the sram black boxes
set_input_delay -clock $clk_name -max 0.46 i_cache_subsystem/i_wt_dcache/i_wt_dcache_mem/gen_tag_srams_*__i_tag_sram/gen_cut_*__gen_mem_i_ram/rddata_do[*]
set_input_delay -clock $clk_name -max 0.46 i_cache_subsystem/i_wt_dcache/i_wt_dcache_mem/gen_data_banks_*__i_data_sram/gen_cut_*__gen_mem_i_ram/rddata_do[*]
set_input_delay -clock $clk_name -max 0.46 i_cache_subsystem/i_cva6_icache/gen_sram_*__data_sram/gen_cut_*__gen_mem_i_ram/rddata_do[*]
set_input_delay -clock $clk_name -max 0.46 i_cache_subsystem/i_cva6_icache/gen_sram_*__tag_sram/gen_cut_*__gen_mem_i_ram/rddata_do[*]

set_output_delay 0.11 -max -clock $clk_name i_cache_subsystem/i_wt_dcache/i_wt_dcache_mem/gen_tag_srams_*__i_tag_sram/addr_i[*]
set_output_delay 0.11 -max -clock $clk_name i_cache_subsystem/i_wt_dcache/i_wt_dcache_mem/gen_data_banks_*__i_data_sram/addr_i[*]
set_output_delay 0.11 -max -clock $clk_name i_cache_subsystem/i_cva6_icache/gen_sram_*__data_sram/addr_i[*]
set_output_delay 0.11 -max -clock $clk_name i_cache_subsystem/i_cva6_icache/gen_sram_*__tag_sram/addr_i[*]

# Check the current design for consistency
check_design -summary > ${DCRM_CHECK_DESIGN_REPORT}

compile_ultra -gate_clock -scan -no_boundary_optimization

change_names -rules verilog -hierarchy

write -format verilog -hierarchy -output ${DCRM_FINAL_VERILOG_OUTPUT_FILE}
write -format verilog -hierarchy -output ${DESIGN_NAME}_synth.v
write -format ddc     -hierarchy -output ${DCRM_FINAL_DDC_OUTPUT_FILE}

report_timing -nworst 10  >  ${DCRM_FINAL_TIMING_REPORT}
report_timing -through i_cache_subsystem/i_wt_dcache/i_wt_dcache_mem/gen_tag_srams_*__i_tag_sram/gen_cut_*__gen_mem_i_ram/rddata_do[*] >>  ${DCRM_FINAL_TIMING_REPORT}
report_timing -through i_cache_subsystem/i_wt_dcache/i_wt_dcache_mem/gen_data_banks_*__i_data_sram/gen_cut_*__gen_mem_i_ram/rddata_do[*] >>  ${DCRM_FINAL_TIMING_REPORT}
report_timing -through i_cache_subsystem/i_cva6_icache/gen_sram_*__data_sram/gen_cut_*__gen_mem_i_ram/rddata_do[*] >>  ${DCRM_FINAL_TIMING_REPORT}
report_timing -through i_cache_subsystem/i_cva6_icache/gen_sram_*__tag_sram/gen_cut_*__gen_mem_i_ram/rddata_do[*] >>  ${DCRM_FINAL_TIMING_REPORT}
report_timing -through i_cache_subsystem/i_wt_dcache/i_wt_dcache_mem/gen_tag_srams_*__i_tag_sram/addr_i[*] >>  ${DCRM_FINAL_TIMING_REPORT}
report_timing -through i_cache_subsystem/i_wt_dcache/i_wt_dcache_mem/gen_data_banks_*__i_data_sram/addr_i[*] >>  ${DCRM_FINAL_TIMING_REPORT}
report_timing -through i_cache_subsystem/i_cva6_icache/gen_sram_*__data_sram/addr_i[*] >>  ${DCRM_FINAL_TIMING_REPORT}
report_timing -through i_cache_subsystem/i_cva6_icache/gen_sram_*__tag_sram/addr_i[*] >>  ${DCRM_FINAL_TIMING_REPORT}

report_power -nosplit > ${REPORTS_DIR}/${DCRM_FINAL_POWER_REPORT}
report_timing -input_pins -capacitance -transition_time -nets -significant_digits 4 -nosplit -nworst 10 -max_paths 10 > ${REPORTS_DIR}/${DESIGN_NAME}.mapped.timing.rpt
report_area -hier -nosplit > ${DCRM_FINAL_AREA_REPORT}
report_clock_gating -nosplit > ${DCRM_FINAL_CLOCK_GATING_REPORT}
report_scan_path > ${DCRM_DFT_FINAL_SCAN_PATH_REPORT}
report_scan_path -chain all -view existing_dft > ${DCRM_DFT_FINAL_SCAN_CHAIN_REPORT}
report_scan_path -cell all > ${DCRM_DFT_FINAL_SCAN_CELL_REPORT}

write_parasitics -output ${DCRM_FINAL_SPEF_OUTPUT_FILE}
write_sdc ${DCRM_FINAL_SDC_OUTPUT_FILE}

exit
