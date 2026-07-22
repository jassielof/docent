//! Shared helpers for lint rules.

const helpers = @import("utils/helpers.zig");
pub const diagnosticSubjectFromDoc = helpers.diagnosticSubjectFromDoc;
pub const diagnosticSubjectKindFromDoc = helpers.diagnosticSubjectKindFromDoc;
pub const dupSourceLine = helpers.dupSourceLine;
pub const isContainerDecl = helpers.isContainerDecl;
pub const isEnumContainer = helpers.isEnumContainer;
pub const isPubVisibility = helpers.isPubVisibility;
pub const moduleDisplayName = helpers.moduleDisplayName;
pub const ownedSubject = helpers.ownedSubject;
pub const ruleIdFromSrc = helpers.ruleIdFromSrc;
pub const ruleIdWithName = helpers.ruleIdWithName;
