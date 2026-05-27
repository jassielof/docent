//! The `fun_max_params` namespace provides checks for the maximum number of function parameters.
//!
//! The maximum number of parameters in many tools and teams often default to around 3-5 to encourage simpler APIs. In Zig, however, it is common to pass interface parameters such as allocators, Writergate, I/O interfaces, etc. as explicit dependencies. To be gentler and more focused on true domain-specific parameters, the default limit here is set to 7.

