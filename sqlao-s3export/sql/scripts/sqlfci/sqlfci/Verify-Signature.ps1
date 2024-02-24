#The following command was used to sign the file
#aws kms sign --key-id alias/sample-sign-verify-key --message-type RAW --signing-algorithm RSASSA_PKCS1_V1_5_SHA_256 --message fileb://../unsigned.txt --output text --query Signature | base64 --decode > sig.dat
#The public key was extracted using the following command (it's available via the Console as well):
#aws kms get-public-key --key-id alias/ScriptSigningKey --output text --query PublicKey | base64 --decode > SamplePublicKey.der
#It was then processed further to extract the raw modulus and exponent for convenience

#----------------Main----------------------
$code = @"
using System;
using System.IO;
using System.Security.Cryptography;
namespace Crypto {
    public class CryptoHelper {
        public static bool VerifySignature(string FilePath, string SignatureFilePath) {
            try {
                var modulus = Convert.FromBase64String("68hw9z3PIC7u5VkEoWeOI+f63hf3+FTDidjgEYkbsGVJ/8Yip0tIyk7rw84AEA9mlZ8c9k5U0dZo18fLGYhRkfgytLVwaXXU8083DwTGj5n8TvTrKss8ugschfGQJIanyWR7eRFLxuYZS5fo2lxur8K+6rc7yDgM+zQTzoOz2GDcTMm3MY3aST9/SShmJLoc6yoekXifyCebSFt8PZ0lmARFiHupepDrZlqXKY/490MlEiZz2fh7RjOORTDZo85Ai/prxxRuHnXrlIBDCbWfCqPCphJD9IMYcbFUxMfL1M7WXCheAtPpzJjMpdLQ+QIzOY1gdvTxx9ml4BtcdXyyE1BE0gFmR8QHBzJIE6KWE7OSEQpPnqwJ+zkA79Mr9/Ud4gdKeI2rGWN7quspSn7nCXcfbG+j9Rc0JMpKgaVLhfXxC0/xWS6JO4HCgrfh5rXWjAN+HVeHDI2iuPOALrHSUPK9hFudqDWSCEhBO3WcVTeg7dzU2M8rx92ypfbThEhczwXQ3yXGbojUzEPv8M24tOsjDZtPlyErE9xwtVY4UBUuJPsjbxLYx/Bq8Fg79liIVITRDH+UQFGws3YZe8EqSOpyk8hY6rOXXXU0uVLpjMny1tmxngdFRaTnQtNUoqV4NBT1wTTSNKEx/O04fEfU7Jha6oaeZ1NaL4F4wApmAh0=");
                var exponent = Convert.FromBase64String("AQAB");
                var rsa = RSA.Create(new RSAParameters {Exponent = exponent, Modulus = modulus});
                using (var stream = File.OpenRead(FilePath)) {
                    var signatureBytes = File.ReadAllBytes(SignatureFilePath);
                    var bytesToVerify = SHA256.Create().ComputeHash(stream);
                    return rsa.VerifyData(bytesToVerify, signatureBytes, HashAlgorithmName.SHA256, RSASignaturePadding.Pkcs1);
                }
            } catch (Exception e) {
                Console.WriteLine(e.ToString());
                return false;
            }
        }
    }
}
"@
Add-Type -TypeDefinition $code -Language CSharp
$VerifySig = [Crypto.CryptoHelper]::VerifySignature('C:\cfn\Adscripts.zip', 'C:\cfn\Adscripts.zip.sig')
#$VerifySig = Invoke-Expression $code
If ($VerifySig)
{
    Write-Output " Signature Verified"
}
else {
     Write-Output "Signature verification failed"
     exit 1
}



