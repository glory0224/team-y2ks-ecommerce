"""
S3의 products.json에서 article_id 읽어서
Kaggle H&M 이미지 다운로드 → S3 업로드 → products.json image URL 업데이트
실행: python scripts/upload_images.py --bucket y2ks-recommend-data-951913065915
"""
import boto3, json, os, subprocess, tempfile, argparse
from concurrent.futures import ThreadPoolExecutor, as_completed

S3_IMAGE_PREFIX = 'hm-images'

def article_id_to_path(article_id_str):
    padded = article_id_str.zfill(10)
    folder = padded[:3]
    return f'images/{folder}/{padded}.jpg'

def download_and_upload(article_id_str, bucket, s3_client, tmp_dir):
    padded = article_id_str.zfill(10)
    kaggle_path = article_id_to_path(article_id_str)
    s3_key = f'{S3_IMAGE_PREFIX}/{padded}.jpg'

    try:
        local_path = os.path.join(tmp_dir, f'{padded}.jpg')
        env = os.environ.copy()
        env['KAGGLE_API_TOKEN'] = 'KGAT_3a541e780528bc3b86a92da52b360606'
        result = subprocess.run(
            ['kaggle', 'competitions', 'download',
             '-c', 'h-and-m-personalized-fashion-recommendations',
             '-f', kaggle_path, '-p', tmp_dir],
            env=env, capture_output=True, timeout=30
        )
        if result.returncode != 0:
            return article_id_str, None

        downloaded = os.path.join(tmp_dir, f'{padded}.jpg')
        if not os.path.exists(downloaded):
            return article_id_str, None

        s3_client.upload_file(
            downloaded, bucket, s3_key,
            ExtraArgs={'ContentType': 'image/jpeg'}
        )
        os.remove(downloaded)
        url = f'https://{bucket}.s3.ap-northeast-2.amazonaws.com/{s3_key}'
        return article_id_str, url
    except Exception as e:
        return article_id_str, None

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--bucket', required=True)
    parser.add_argument('--region', default='ap-northeast-2')
    parser.add_argument('--workers', type=int, default=8)
    args = parser.parse_args()

    s3 = boto3.client('s3', region_name=args.region)

    print('products.json 로드...')
    obj = s3.get_object(Bucket=args.bucket, Key='products.json')
    products = json.loads(obj['Body'].read())

    article_ids = [p['id'].replace('hm', '') for p in products]
    print(f'{len(article_ids)}개 이미지 다운로드 시작 (workers={args.workers})')

    id_to_url = {}
    with tempfile.TemporaryDirectory() as tmp_dir:
        with ThreadPoolExecutor(max_workers=args.workers) as executor:
            futures = {
                executor.submit(download_and_upload, aid, args.bucket, s3, tmp_dir): aid
                for aid in article_ids
            }
            done = 0
            for future in as_completed(futures):
                aid, url = future.result()
                done += 1
                if url:
                    id_to_url[aid] = url
                if done % 50 == 0:
                    print(f'  {done}/{len(article_ids)} 완료 (성공: {len(id_to_url)})')

    print(f'이미지 업로드 완료: {len(id_to_url)}/{len(article_ids)}')

    for p in products:
        aid = p['id'].replace('hm', '')
        if aid in id_to_url:
            p['image'] = id_to_url[aid]

    s3.put_object(
        Bucket=args.bucket,
        Key='products.json',
        Body=json.dumps(products, ensure_ascii=False),
        ContentType='application/json'
    )
    print('products.json 업데이트 완료')

if __name__ == '__main__':
    main()
