import { Router, Request, Response } from 'express';
import multer from 'multer';
import tar from 'tar';
import fs from 'fs/promises';
import path from 'path';
import semver from 'semver';
import { mongoDb, logger } from '../server';
import { authMiddleware } from '../middleware/auth';
import { validatePackage } from '../validators/package';

export const packageRouter = Router();

// Configure multer for package uploads
const storage = multer.diskStorage({
    destination: async (req, file, cb) => {
        const uploadDir = path.join(process.cwd(), 'uploads');
        await fs.mkdir(uploadDir, { recursive: true });
        cb(null, uploadDir);
    },
    filename: (req, file, cb) => {
        cb(null, `${Date.now()}-${file.originalname}`);
    }
});

const upload = multer({
    storage,
    limits: {
        fileSize: 50 * 1024 * 1024 // 50MB max
    },
    fileFilter: (req, file, cb) => {
        if (file.mimetype === 'application/gzip' || file.originalname.endsWith('.tgz')) {
            cb(null, true);
        } else {
            cb(new Error('Only .tgz files are allowed'));
        }
    }
});

// GET /api/packages - List all packages
packageRouter.get('/', async (req: Request, res: Response) => {
    try {
        const page = parseInt(req.query.page as string) || 1;
        const limit = parseInt(req.query.limit as string) || 20;
        const skip = (page - 1) * limit;

        const packages = await mongoDb
            .collection('packages')
            .find({})
            .sort({ downloadCount: -1, createdAt: -1 })
            .skip(skip)
            .limit(limit)
            .toArray();

        const total = await mongoDb.collection('packages').countDocuments();

        res.json({
            packages,
            pagination: {
                page,
                limit,
                total,
                totalPages: Math.ceil(total / limit)
            }
        });
    } catch (error) {
        logger.error('Error fetching packages', { error });
        res.status(500).json({ error: 'Failed to fetch packages' });
    }
});

// GET /api/packages/:name - Get package by name
packageRouter.get('/:name', async (req: Request, res: Response) => {
    try {
        const { name } = req.params;

        const pkg = await mongoDb.collection('packages').findOne({ name });

        if (!pkg) {
            return res.status(404).json({ error: 'Package not found' });
        }

        res.json(pkg);
    } catch (error) {
        logger.error('Error fetching package', { error, name: req.params.name });
        res.status(500).json({ error: 'Failed to fetch package' });
    }
});

// GET /api/packages/:name/:version - Get specific version
packageRouter.get('/:name/:version', async (req: Request, res: Response) => {
    try {
        const { name, version } = req.params;

        const pkg = await mongoDb.collection('packages').findOne({ name });

        if (!pkg) {
            return res.status(404).json({ error: 'Package not found' });
        }

        const versionData = pkg.versions.find((v: any) => v.version === version);

        if (!versionData) {
            return res.status(404).json({ error: 'Version not found' });
        }

        res.json({
            ...pkg,
            version: versionData
        });
    } catch (error) {
        logger.error('Error fetching package version', {
            error,
            name: req.params.name,
            version: req.params.version
        });
        res.status(500).json({ error: 'Failed to fetch package version' });
    }
});

// POST /api/packages - Publish a new package
packageRouter.post(
    '/',
    authMiddleware,
    upload.single('package'),
    async (req: Request, res: Response) => {
        try {
            if (!req.file) {
                return res.status(400).json({ error: 'No package file provided' });
            }

            // Extract and validate package metadata
            const metadata = await extractPackageMetadata(req.file.path);
            const validation = validatePackage(metadata);

            if (!validation.valid) {
                await fs.unlink(req.file.path);
                return res.status(400).json({
                    error: 'Invalid package',
                    issues: validation.errors
                });
            }

            // Check if package exists
            const existingPkg = await mongoDb.collection('packages').findOne({
                name: metadata.name
            });

            if (existingPkg) {
                // Check if version already exists
                const versionExists = existingPkg.versions.some(
                    (v: any) => v.version === metadata.version
                );

                if (versionExists) {
                    await fs.unlink(req.file.path);
                    return res.status(409).json({
                        error: 'Version already exists'
                    });
                }

                // Add new version
                await mongoDb.collection('packages').updateOne(
                    { name: metadata.name },
                    {
                        $push: {
                            versions: {
                                version: metadata.version,
                                description: metadata.description,
                                tarball: `/packages/${path.basename(req.file.path)}`,
                                publishedAt: new Date(),
                                dependencies: metadata.dependencies || {}
                            }
                        },
                        $set: {
                            latestVersion: metadata.version,
                            updatedAt: new Date()
                        }
                    }
                );
            } else {
                // Create new package
                await mongoDb.collection('packages').insertOne({
                    name: metadata.name,
                    description: metadata.description,
                    author: metadata.author,
                    license: metadata.license,
                    homepage: metadata.homepage,
                    repository: metadata.repository,
                    keywords: metadata.keywords || [],
                    latestVersion: metadata.version,
                    versions: [
                        {
                            version: metadata.version,
                            description: metadata.description,
                            tarball: `/packages/${path.basename(req.file.path)}`,
                            publishedAt: new Date(),
                            dependencies: metadata.dependencies || {}
                        }
                    ],
                    downloadCount: 0,
                    createdAt: new Date(),
                    updatedAt: new Date(),
                    publishedBy: (req as any).user?.username || 'unknown'
                });
            }

            // Move file to permanent storage
            const storagePath = path.join(
                process.env.STORAGE_PATH || './storage',
                path.basename(req.file.path)
            );
            await fs.rename(req.file.path, storagePath);

            logger.info('Package published', {
                name: metadata.name,
                version: metadata.version,
                user: (req as any).user?.username
            });

            res.status(201).json({
                message: 'Package published successfully',
                package: metadata.name,
                version: metadata.version
            });
        } catch (error) {
            logger.error('Error publishing package', { error });
            res.status(500).json({ error: 'Failed to publish package' });
        }
    }
);

// DELETE /api/packages/:name/:version - Unpublish a version
packageRouter.delete(
    '/:name/:version',
    authMiddleware,
    async (req: Request, res: Response) => {
        try {
            const { name, version } = req.params;

            const pkg = await mongoDb.collection('packages').findOne({ name });

            if (!pkg) {
                return res.status(404).json({ error: 'Package not found' });
            }

            // Remove version
            await mongoDb.collection('packages').updateOne(
                { name },
                {
                    $pull: { versions: { version } },
                    $set: { updatedAt: new Date() }
                }
            );

            logger.info('Package version unpublished', {
                name,
                version,
                user: (req as any).user?.username
            });

            res.json({
                message: 'Version unpublished successfully',
                package: name,
                version
            });
        } catch (error) {
            logger.error('Error unpublishing version', { error });
            res.status(500).json({ error: 'Failed to unpublish version' });
        }
    }
);

// POST /api/packages/:name/download - Track download
packageRouter.post('/:name/download', async (req: Request, res: Response) => {
    try {
        const { name } = req.params;

        await mongoDb.collection('packages').updateOne(
            { name },
            { $inc: { downloadCount: 1 } }
        );

        res.json({ message: 'Download tracked' });
    } catch (error) {
        logger.error('Error tracking download', { error });
        res.status(500).json({ error: 'Failed to track download' });
    }
});

// Helper function to extract package metadata
async function extractPackageMetadata(filePath: string): Promise<any> {
    // This is a simplified version - in practice, you'd extract from the tarball
    const buffer = await fs.readFile(filePath);

    // For now, return mock metadata
    // In real implementation, extract package.ion from tarball
    return {
        name: 'example-package',
        version: '1.0.0',
        description: 'Example package',
        author: 'Ion Team',
        license: 'MIT',
        keywords: ['example'],
        dependencies: {}
    };
}
