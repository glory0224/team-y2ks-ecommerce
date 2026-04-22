"""
H&M articles.csv → 상품 500개 필터링 → S3 products.json 업로드
실행: python scripts/seed.py --bucket <버킷명>
"""
import pandas as pd, json, boto3, argparse, random

CATEGORY_KO = {
    'Garment Upper body': '상의', 'Garment Lower body': '하의',
    'Garment Full body': '원피스', 'Shoes': '신발', 'Bags': '가방',
    'Accessories': '소품', 'Underwear/nightwear': '이너웨어',
    'Swimwear': '수영복', 'Socks & Tights': '양말', 'Nightwear': '홈웨어',
}
COLOUR_KO = {
    'Black': '블랙', 'White': '화이트', 'Blue': '블루', 'Grey': '그레이',
    'Beige': '베이지', 'Pink': '핑크', 'Red': '레드', 'Green': '그린',
    'Brown': '브라운', 'Yellow': '옐로우', 'Orange': '오렌지',
    'Purple': '퍼플', 'Navy Blue': '네이비', 'Off White': '오프화이트',
    'Light Blue': '라이트블루', 'Dark Blue': '다크블루', 'Light Grey': '라이트그레이',
    'Dark Grey': '다크그레이', 'Khaki green': '카키', 'Dusty Pink': '더스티핑크',
}
PRICE_RANGE = {
    'Garment Upper body': (29000, 89000), 'Garment Lower body': (39000, 89000),
    'Garment Full body': (59000, 129000), 'Shoes': (59000, 159000),
    'Bags': (29000, 99000), 'Accessories': (15000, 49000),
}

S3 = 'https://y2ks-product-images.s3.ap-northeast-2.amazonaws.com'
TYPE_IMAGE = {
    'T-shirt':            f'{S3}/black-tshirt.jpg',
    'Top':                f'{S3}/black-tshirt.jpg',
    'Vest top':           f'{S3}/linen-vest.jpg',
    'Blouse':             f'{S3}/linen-blouse.jpg',
    'Shirt':              f'{S3}/flannel-shirt.jpg',
    'Sweater':            f'{S3}/knit-sweater.jpg',
    'Cardigan':           f'{S3}/cardigan.jpg',
    'Hoodie':             f'{S3}/cardigan.jpg',
    'Jacket':             f'{S3}/denim-jacket.jpg',
    'Blazer':             f'{S3}/denim-jacket.jpg',
    'Coat':               f'{S3}/bomber-jacket.jpg',
    'Dress':              f'{S3}/linen-blouse.jpg',
    'Jumpsuit/Playsuit':  f'{S3}/linen-blouse.jpg',
    'Bodysuit':           f'{S3}/linen-vest.jpg',
    'Trousers':           f'{S3}/flannel-shirt.jpg',
    'Skirt':              f'{S3}/linen-blouse.jpg',
    'Shorts':             f'{S3}/linen-vest.jpg',
    'Leggings/Tights':    f'{S3}/black-tshirt.jpg',
    'Bag':                f'{S3}/linen-vest.jpg',
    'Sneakers':           f'{S3}/bomber-jacket.jpg',
    'Boots':              f'{S3}/denim-jacket.jpg',
    'Sandals':            f'{S3}/bomber-jacket.jpg',
}
DEFAULT_IMAGES = [
    f'{S3}/flannel-shirt.jpg', f'{S3}/knit-sweater.jpg',
    f'{S3}/denim-jacket.jpg',  f'{S3}/black-tshirt.jpg',
    f'{S3}/cardigan.jpg',      f'{S3}/linen-vest.jpg',
    f'{S3}/linen-blouse.jpg',  f'{S3}/bomber-jacket.jpg',
]

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--bucket', required=True, help='S3 버킷명 (예: y2ks-recommend-data-123456789)')
    parser.add_argument('--csv', default='scripts/articles.csv', help='articles.csv 경로')
    parser.add_argument('--count', type=int, default=500)
    parser.add_argument('--region', default='ap-northeast-2')
    args = parser.parse_args()

    print(f'Loading {args.csv}...')
    df = pd.read_csv(args.csv)

    target_groups = ['Garment Upper body', 'Garment Lower body', 'Garment Full body', 'Shoes', 'Bags', 'Accessories']
    df = df[df['product_group_name'].isin(target_groups)].copy()
    df = df[df['index_group_name'].isin(['Ladieswear', 'Divided'])].copy()
    df = df.dropna(subset=['product_type_name', 'colour_group_name', 'detail_desc'])
    df = df.drop_duplicates(subset=['product_type_name', 'colour_group_name'])

    if len(df) > args.count:
        df = df.sample(args.count, random_state=42)

    print(f'Processing {len(df)} products...')
    products = []
    for _, row in df.iterrows():
        pid = f"hm{row['article_id']}"
        group = row['product_group_name']
        colour = row['colour_group_name']
        colour_ko = COLOUR_KO.get(colour, colour)
        category_ko = CATEGORY_KO.get(group, group)
        name = f"{colour_ko} {row['product_type_name']}"
        lo, hi = PRICE_RANGE.get(group, (29000, 99000))
        price = random.randrange(lo, hi, 1000)
        tags = [
            row['product_type_name'],
            colour,
            row.get('department_name', ''),
            row.get('section_name', ''),
            row.get('graphical_appearance_name', ''),
        ]
        tags = [t for t in tags if isinstance(t, str) and t.strip()]
        ptype = row['product_type_name']
        image = TYPE_IMAGE.get(ptype, DEFAULT_IMAGES[int(row['article_id']) % len(DEFAULT_IMAGES)])
        products.append({
            'id': pid,
            'name': name,
            'brand': 'H&M',
            'category': category_ko,
            'price': price,
            'badge': '',
            'image': image,
            'tags': tags,
            'weight': round(random.uniform(0.7, 1.0), 2),
        })

    print(f'Uploading {len(products)} products to s3://{args.bucket}/products.json ...')
    s3 = boto3.client('s3', region_name=args.region)
    try:
        s3.create_bucket(
            Bucket=args.bucket,
            CreateBucketConfiguration={'LocationConstraint': args.region}
        )
        print(f'Bucket {args.bucket} created.')
    except s3.exceptions.BucketAlreadyOwnedByYou:
        pass
    except Exception as e:
        print(f'Bucket note: {e}')

    s3.put_object(
        Bucket=args.bucket,
        Key='products.json',
        Body=json.dumps(products, ensure_ascii=False),
        ContentType='application/json'
    )
    print(f'Done. {len(products)} products uploaded.')
    print(f'\n버킷명을 recommend.py RECOMMEND_BUCKET 환경변수에 설정하세요:')
    print(f'  RECOMMEND_BUCKET={args.bucket}')

if __name__ == '__main__':
    main()
