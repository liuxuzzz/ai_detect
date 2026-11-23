use anyhow::{anyhow, Context};
use ring::{
    aead, hkdf,
    rand::{SecureRandom, SystemRandom},
};

pub(crate) struct KeyCipher(aead::LessSafeKey);

impl KeyCipher {
    pub(crate) fn new(secret: &str) -> anyhow::Result<Self> {
        let salt = hkdf::Salt::new(hkdf::HKDF_SHA256, b"aijiance/client-key-encryption/v1");
        let prk = salt.extract(secret.as_bytes());
        let mut key = [0; 32];
        prk.expand(&[], hkdf::HKDF_SHA256)
            .and_then(|output| output.fill(&mut key))
            .map_err(|_| anyhow!("Client Key 加密初始化失败"))?;
        let key = aead::UnboundKey::new(&aead::AES_256_GCM, &key)
            .map_err(|_| anyhow!("Client Key 加密初始化失败"))?;
        Ok(Self(aead::LessSafeKey::new(key)))
    }

    pub(crate) fn encrypt(&self, owner: i64, key: &str) -> anyhow::Result<Vec<u8>> {
        let mut nonce_bytes = [0; aead::NONCE_LEN];
        SystemRandom::new()
            .fill(&mut nonce_bytes)
            .map_err(|_| anyhow!("无法生成随机数"))?;
        let nonce = aead::Nonce::assume_unique_for_key(nonce_bytes);
        let mut ciphertext = key.as_bytes().to_vec();
        self.0
            .seal_in_place_append_tag(nonce, aead::Aad::from(owner.to_be_bytes()), &mut ciphertext)
            .map_err(|_| anyhow!("Client Key 加密失败"))?;
        Ok([nonce_bytes.as_slice(), &ciphertext].concat())
    }

    pub(crate) fn decrypt(&self, owner: i64, mut ciphertext: Vec<u8>) -> anyhow::Result<String> {
        let (nonce, encrypted) = ciphertext
            .split_at_mut_checked(aead::NONCE_LEN)
            .context("Client Key 密文无效")?;
        let nonce = aead::Nonce::try_assume_unique_for_key(nonce)
            .map_err(|_| anyhow!("Client Key 密文无效"))?;
        let key = self
            .0
            .open_in_place(nonce, aead::Aad::from(owner.to_be_bytes()), encrypted)
            .map_err(|_| anyhow!("Client Key 解密失败"))?;
        Ok(std::str::from_utf8(key)?.to_owned())
    }
}
