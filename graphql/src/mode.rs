#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum RuntimeMode {
    Production,
    Testing,
}

impl RuntimeMode {
    pub fn from_env() -> Result<Self, std::io::Error> {
        match std::env::var_os("MODE") {
            None => Ok(Self::Production),
            Some(value) => {
                let value = value.into_string().map_err(|_| {
                    std::io::Error::new(std::io::ErrorKind::InvalidData, "MODE must be valid UTF-8")
                })?;
                Self::parse(Some(&value))
                    .map_err(|error| std::io::Error::new(std::io::ErrorKind::InvalidInput, error))
            }
        }
    }

    fn parse(value: Option<&str>) -> Result<Self, String> {
        match value {
            None | Some("production") => Ok(Self::Production),
            Some("testing") => Ok(Self::Testing),
            Some(value) => Err(format!(
                "Invalid MODE={value:?}; expected 'production' or 'testing'"
            )),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::RuntimeMode;
    use std::ffi::OsString;
    use std::sync::Mutex;

    static ENVIRONMENT_LOCK: Mutex<()> = Mutex::new(());

    struct RestoreEnvironment {
        mode: Option<OsString>,
        production: Option<OsString>,
    }

    impl Drop for RestoreEnvironment {
        fn drop(&mut self) {
            match self.mode.take() {
                Some(value) => std::env::set_var("MODE", value),
                None => std::env::remove_var("MODE"),
            }
            match self.production.take() {
                Some(value) => std::env::set_var("PRODUCTION", value),
                None => std::env::remove_var("PRODUCTION"),
            }
        }
    }

    #[test]
    fn defaults_to_production_and_accepts_explicit_modes() {
        assert_eq!(RuntimeMode::parse(None), Ok(RuntimeMode::Production));
        assert_eq!(
            RuntimeMode::parse(Some("production")),
            Ok(RuntimeMode::Production)
        );
        assert_eq!(
            RuntimeMode::parse(Some("testing")),
            Ok(RuntimeMode::Testing)
        );
    }

    #[test]
    fn rejects_empty_unknown_and_non_normalized_modes() {
        for value in ["", "backup", "Production", " production", "testing "] {
            assert!(RuntimeMode::parse(Some(value)).is_err(), "{value:?}");
        }
    }

    #[test]
    fn ignores_legacy_environment_values() {
        let _lock = ENVIRONMENT_LOCK.lock().unwrap();
        let _restore = RestoreEnvironment {
            mode: std::env::var_os("MODE"),
            production: std::env::var_os("PRODUCTION"),
        };
        std::env::remove_var("MODE");
        for legacy_value in ["", "true", "false"] {
            std::env::set_var("PRODUCTION", legacy_value);
            assert_eq!(RuntimeMode::from_env().unwrap(), RuntimeMode::Production);
        }
        std::env::set_var("MODE", "testing");
        std::env::set_var("PRODUCTION", "true");
        assert_eq!(RuntimeMode::from_env().unwrap(), RuntimeMode::Testing);
    }
}
