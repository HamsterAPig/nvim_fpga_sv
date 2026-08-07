; extends

(interface_declaration
  name: (simple_identifier) @fpga_sv.interface)

(modport_declaration
  (modport_item
    (simple_identifier) @fpga_sv.modport))

(module_instantiation
  (hierarchical_instance
    (name_of_instance
      instance_name: (simple_identifier) @fpga_sv.instance)))

(interface_instantiation
  (hierarchical_instance
    (name_of_instance
      instance_name: (simple_identifier) @fpga_sv.instance)))

(sequence_declaration
  name: (simple_identifier) @fpga_sv.sequence)

(property_declaration
  name: (simple_identifier) @fpga_sv.property)

(covergroup_declaration
  name: (simple_identifier) @fpga_sv.coverage)

(text_macro_definition
  (text_macro_name
    (list_of_formal_arguments
      (formal_argument) @fpga_sv.macro_parameter)))

(concurrent_assertion_item
  (simple_identifier) @fpga_sv.assertion)

(hierarchical_identifier) @fpga_sv.hierarchy
