//! Test-support contracts (mocks). Not part of the framework's trust surface; the
//! cairo-auditor prunes the `mocks/` directory. Compiled into the package so snforge's
//! `declare` can find them.

pub mod account_mock;
pub mod erc20_mock;
pub mod oracle_mock;
pub mod token_mock;
