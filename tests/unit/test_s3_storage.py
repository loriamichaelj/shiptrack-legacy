import base64
import hashlib
import uuid

from botocore.exceptions import ClientError

from shiptrack.storage import s3


def test_s3_uri_is_split_into_bucket_and_key() -> None:
    location = s3.parse_uri("s3://shiptrack-pod-bucket/pod/abc/def")
    assert location == s3.S3Location(bucket="shiptrack-pod-bucket", key="pod/abc/def")
    assert location is not None
    assert location.uri == "s3://shiptrack-pod-bucket/pod/abc/def"


def test_other_schemes_and_incomplete_uris_are_not_s3() -> None:
    assert s3.parse_uri("file:///var/lib/shiptrack/pod/a/b") is None
    assert s3.parse_uri("https://example.test/pod/a") is None
    assert s3.parse_uri("s3://bucket-only") is None
    assert s3.parse_uri("s3:///no-bucket/key") is None


def test_the_key_is_the_one_the_modern_stack_uses() -> None:
    shipment, document = uuid.uuid4(), uuid.uuid4()
    assert s3.proof_of_delivery_key(shipment, document) == f"pod/{shipment}/{document}"


def test_checksum_is_base64_of_the_raw_digest() -> None:
    digest = hashlib.sha256(b"proof").hexdigest()
    assert base64.b64decode(s3.sha256_checksum(digest)) == hashlib.sha256(b"proof").digest()


def test_not_found_is_recognised_only_for_missing_objects() -> None:
    missing = ClientError({"Error": {"Code": "NoSuchKey", "Message": ""}}, "GetObject")
    denied = ClientError({"Error": {"Code": "AccessDenied", "Message": ""}}, "GetObject")
    assert s3.is_not_found(missing)
    assert not s3.is_not_found(denied)
    assert not s3.is_not_found(RuntimeError("not a client error"))
