//! 发送前的硬闸:可测试的保证,不是尽力而为。命中即拒发,调用方退回本地正则路径。
use crate::{DeidError, KnownIdentity};

pub fn assert_clean(payload: &str, known: &KnownIdentity) -> Result<(), DeidError> {
    if known.name.chars().count() >= 2 && payload.contains(known.name.as_str()) {
        return Err(DeidError::IdentityLeak("姓名".into()));
    }
    if known
        .id_number
        .as_deref()
        .filter(|s| !s.is_empty())
        .is_some_and(|id| payload.contains(id))
    {
        return Err(DeidError::IdentityLeak("证件号".into()));
    }
    if known
        .phone
        .as_deref()
        .filter(|s| !s.is_empty())
        .is_some_and(|p| payload.contains(p))
    {
        return Err(DeidError::IdentityLeak("手机号".into()));
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::KnownIdentity;

    fn k() -> KnownIdentity {
        KnownIdentity {
            name: "张建国".into(),
            id_number: Some("110101199001011234".into()),
            phone: None,
        }
    }

    #[test]
    fn clean_payload_passes() {
        assert!(assert_clean("白细胞 5.6 [P1] [N1]", &k()).is_ok());
    }

    #[test]
    fn leaked_name_is_refused_without_echoing_it() {
        let e = assert_clean("姓名:张建国", &k()).unwrap_err().to_string();
        assert!(e.contains("姓名"));
        assert!(!e.contains("张建国"), "错误信息不能回显身份:{e}");
    }

    #[test]
    fn leaked_id_is_refused() {
        assert!(assert_clean("证件 110101199001011234", &k()).is_err());
    }
}
