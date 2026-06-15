//! Shared helpers for lint rules.

const helpers = @import("utils/helpers.zig");

pub const ownedSubject = helpers.ownedSubject;
pub const moduleDisplayName = helpers.moduleDisplayName;
pub const isContainerDecl = helpers.isContainerDecl;
pub const isEnumContainer = helpers.isEnumContainer;
pub const isPubVisibility = helpers.isPubVisibility;
pub const shouldCheckDocCommentTarget = helpers.shouldCheckDocCommentTarget;
pub const resolveDocCommentSubject = helpers.resolveDocCommentSubject;
pub const docCommentLineBody = helpers.docCommentLineBody;
pub const isEmptyDocCommentLine = helpers.isEmptyDocCommentLine;
pub const fileIsNamespace = helpers.fileIsNamespace;
pub const exposedSourceFileSubjectKind = helpers.exposedSourceFileSubjectKind;
pub const hasContainerDocComment = helpers.hasContainerDocComment;
pub const containerDocBlockIsFullyBlank = helpers.containerDocBlockIsFullyBlank;
pub const dupSourceLine = helpers.dupSourceLine;
pub const ruleIdFromSrc = helpers.ruleIdFromSrc;
pub const ruleIdWithName = helpers.ruleIdWithName;
