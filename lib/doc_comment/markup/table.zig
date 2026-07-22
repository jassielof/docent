//! Table, table-row, and table-cell block nodes in Zig doc-comment markup.

const Document = @import("Document.zig");
pub const TableCellAlignment = Document.Node.TableCellAlignment;
pub const table = Document.Node.Tag.table;
pub const table_cell = Document.Node.Tag.table_cell;
pub const table_row = Document.Node.Tag.table_row;
