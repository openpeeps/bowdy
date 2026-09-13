--deepcopy:on
--define:nimPreviewHashRef
# JIT is always on: vancode's DynASM JIT compiles in every build.
switch("define", "vancodeJitDynasm")